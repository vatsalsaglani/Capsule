import SwiftUI

@main
struct CapsuleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // Menu-bar extra (plan §3): runtime up/down, running count, stop-all,
        // per-project status dots — wired to the EventBus during M1.
        MenuBarExtra("Capsule", systemImage: "capsule.portrait.fill") {
            MenuBarView()
        }
    }
}

struct MenuBarView: View {
    var body: some View {
        Text("Capsule — pre-alpha")
        Divider()
        Button("Quit Capsule") {
            NSApplication.shared.terminate(nil)
        }
    }
}
