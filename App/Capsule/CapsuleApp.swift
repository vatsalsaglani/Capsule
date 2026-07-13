import AppCore
import RuntimeInstaller
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
    // Constructed at the app root (P1D) rather than folded into
    // `RuntimeSession`: `RuntimeSession`'s construction already commits to a
    // `ContainerRuntime` (or the permanent `.runtimeMissing` fallback) once
    // at init and never re-locates the binary afterwards, but install/update
    // checking must re-probe on every `refresh()` (re-check on activation —
    // the binary can appear or change version *after* launch, once the user
    // runs a downloaded installer outside Capsule). One shared instance
    // still, matching the B1 "construct once" directive — just a sibling of
    // `session`, not a member of it.
    @State private var runtimeInstaller = RuntimeInstallerModel()
    @State private var cliInstallStore = CapsuleCLIInstallStore()
    #if DEBUG
    @State private var demoSession = ScriptedDemoSession()
    #endif

    init() {
        appDelegate.session = session
        #if DEBUG
        appDelegate.demoSession = demoSession
        #endif
    }

    /// The menu-bar mark (plan §6). Resolved with a fallback chain so it works
    /// in every build shape: the compiled asset catalog (`MenuBarIcon`, real
    /// Xcode/xcodegen build), a loose `MenuBarIcon.png` in the bundle
    /// (environments where `actool` can't compile the catalog), then the SF
    /// Symbol as a last resort. Rendered as a template so the menu bar tints
    /// it for light/dark automatically.
    static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Capsule")!
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .environment(runtimeInstaller)
                .environment(cliInstallStore)
                .task { await session.start() }
                .task { await runtimeInstaller.refresh() }
        }

        // Menu-bar extra (plan §3): runtime up/down, running count, stop-all —
        // fed by the same shared `RuntimeSession`/`EventBus`, never a second
        // poller (see `RuntimeSession`'s doc comment).
        MenuBarExtra {
            MenuBarView(menuBar: session.menuBar)
        } label: {
            Image(nsImage: Self.menuBarIcon)
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
