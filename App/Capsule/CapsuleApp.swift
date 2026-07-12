import AppCore
import SwiftUI

/// Owns the one `RuntimeSession` stop() call site. Per the P1B B1
/// architecture directive: `RuntimeSession` starts once at launch and stops
/// only at app termination, never tied to any individual window/menu-bar
/// scene's own lifecycle — `NSApplicationDelegateAdaptor` is the mechanism
/// that gives us a hook outside SwiftUI's scene lifecycle for that.
final class CapsuleAppDelegate: NSObject, NSApplicationDelegate {
    var session: RuntimeSession?
    #if DEBUG
    var demoSession: ScriptedDemoSession?
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort: `stop()` is async (cancels the poller's task and
        // unsubscribes the containers store from the bus) and the process
        // may exit before it fully drains — acceptable, since nothing here
        // needs to survive process exit. What the B1 directive actually
        // requires is *scope* (this is the only stop() call site, never a
        // scene appear/disappear), not synchronous completion before return.
        if let session {
            Task { await session.stop() }
        }
        #if DEBUG
        if let demoSession {
            Task { await demoSession.stop() }
        }
        #endif
    }
}

@main
struct CapsuleApp: App {
    @NSApplicationDelegateAdaptor(CapsuleAppDelegate.self) private var appDelegate
    @State private var session = RuntimeSession()
    #if DEBUG
    @State private var demoSession = ScriptedDemoSession()
    #endif

    init() {
        appDelegate.session = session
        #if DEBUG
        appDelegate.demoSession = demoSession
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .task { await session.start() }
        }

        // Menu-bar extra (plan §3): runtime up/down, running count, stop-all —
        // fed by the same shared `RuntimeSession`/`EventBus`, never a second
        // poller (see `RuntimeSession`'s doc comment).
        MenuBarExtra("Capsule", systemImage: "capsule.portrait.fill") {
            MenuBarView(menuBar: session.menuBar)
        }

        #if DEBUG
        // P1B B2 feel-prototype review window — appears in the Window menu;
        // never shipped (whole scene compiled out of Release builds).
        Window("Feel Prototype (Debug)", id: "capsule-feel-prototype") {
            FeelPrototypeDemoView(demoSession: demoSession)
        }
        #endif
    }
}

/// The real menu-bar extra content (P1B B6) — status dot, running count,
/// stop-all, and a way back to the main window, all fed by the *shared*
/// `RuntimeSession`'s `MenuBarStore` (never a second session/poller; see
/// `RuntimeSession`'s doc comment — `CapsuleApp` constructs exactly one
/// `RuntimeSession` and passes its `menuBar` here).
struct MenuBarView: View {
    let menuBar: MenuBarStore

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status dot color goes through the one state-color mapping
        // (`ContainerStateColor`) rather than a bespoke ternary — accent
        // indigo never means state, and "running"/"stopped" already cover
        // the up/down cases this dot needs (§6.7 rule 1).
        Label(
            menuBar.runtimeUp ? "Runtime Running" : "Runtime Unavailable",
            systemImage: menuBar.runtimeUp ? "circle.fill" : "circle"
        )
        .foregroundStyle(ContainerStateColor.color(for: menuBar.runtimeUp ? "running" : "stopped"))
        Text("\(menuBar.runningCount) running")
        Divider()
        Button("Stop All") {
            Task { await menuBar.stopAll() }
        }
        .disabled(menuBar.runningCount == 0)
        Divider()
        Button("Open Capsule") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Capsule") {
            NSApplication.shared.terminate(nil)
        }
    }
}
