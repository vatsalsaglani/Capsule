import Observation

/// Thin derivation over a shared `ContainerListStore` for the menu-bar extra
/// (plan §6 boundary: menu bar and main window both read from one poller/bus
/// via `RuntimeSession`, never a second subscription — two pollers would
/// double the `container list` load, P1B's `RuntimeSession` doc comment).
@MainActor
@Observable
public final class MenuBarStore {
    private let containers: ContainerListStore

    public init(containers: ContainerListStore) {
        self.containers = containers
    }

    /// `true` once the shared store has a loaded container list; `false`
    /// while connecting, when the runtime couldn't be constructed, or during
    /// an outage.
    public var runtimeUp: Bool {
        switch containers.phase {
        case .loaded:
            return true
        case .connecting, .runtimeMissing, .unavailable:
            return false
        }
    }

    public var runningCount: Int {
        containers.runningCount
    }

    public func stopAll() async {
        await containers.stopAllRunning()
    }
}
