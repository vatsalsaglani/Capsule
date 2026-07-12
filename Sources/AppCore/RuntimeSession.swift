import ContainerClient
import EventBus
import Foundation
import Observation

/// Composition root for the app-facing state (P1B B1). Builds the real
/// pipeline — `CLIProcessClient` → `RuntimeGateway` → one shared
/// `EventBus<RuntimeEvent>` + one shared `RuntimePoller` — and exposes the
/// stores built on top of it.
///
/// **Construct once, share everywhere:** a later batch injects a single
/// `RuntimeSession` into both the main window and the menu-bar extra scenes.
/// Two independently-constructed sessions would each own their own poller,
/// doubling `container list` load for no benefit (menu bar's `MenuBarStore`
/// deliberately derives from the *same* `ContainerListStore` rather than
/// re-subscribing the bus, for the same reason). Safe to share: the
/// `EventBus`/`RuntimePoller` underneath are actors, and every store here is
/// `@MainActor`.
///
/// **Runtime-missing handling:** if the runtime can't even be constructed
/// (`RuntimeError.binaryNotFound`, or any other startup failure from
/// `makeRuntime`), `containers` is built directly into
/// `.runtimeMissing(message:)` with the failure's real message — honest
/// install-guidance copy, nothing more. Deep onboarding UX is P1D's
/// boundary.
@MainActor
@Observable
public final class RuntimeSession {
    public let containers: ContainerListStore
    public let menuBar: MenuBarStore

    /// `nil` exactly when construction hit the `runtimeMissing` path — there
    /// is nothing to poll.
    private let poller: RuntimePoller?

    /// Builds the real `CLIProcessClient`-backed pipeline (auto-locates the
    /// `container` binary).
    public convenience init(
        pollInterval: Duration = .seconds(2),
        idleInterval: Duration = .seconds(6),
        unavailableInterval: Duration = .seconds(5)
    ) {
        self.init(
            makeRuntime: { try CLIProcessClient() },
            pollInterval: pollInterval,
            idleInterval: idleInterval,
            unavailableInterval: unavailableInterval
        )
    }

    /// Test/advanced injection point: `makeRuntime` supplies the base
    /// `ContainerRuntime` construction (wrapped in a `RuntimeGateway` here).
    /// A throwing `makeRuntime` (mirroring `CLIProcessClient.init`'s
    /// `RuntimeError.binaryNotFound`) exercises the same `.runtimeMissing`
    /// path production hits, without touching the real `container` binary.
    public init(
        makeRuntime: () throws -> any ContainerRuntime,
        pollInterval: Duration = .seconds(2),
        idleInterval: Duration = .seconds(6),
        unavailableInterval: Duration = .seconds(5)
    ) {
        let events = EventBus<RuntimeEvent>()
        do {
            let base = try makeRuntime()
            let gateway = RuntimeGateway(base: base)
            self.poller = RuntimePoller(
                runtime: gateway,
                events: events,
                interval: pollInterval,
                idleInterval: idleInterval,
                unavailableInterval: unavailableInterval
            )
            self.containers = ContainerListStore(runtime: gateway, events: events)
        } catch {
            self.poller = nil
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self.containers = ContainerListStore(runtimeMissingMessage: message)
        }
        self.menuBar = MenuBarStore(containers: self.containers)
    }

    /// Starts the `containers` store's subscription *before* the shared
    /// poller, in that order — the store's subscription must be registered
    /// on the bus before the poller can publish its first `.snapshot`, or
    /// that snapshot is silently dropped (see `ContainerListStore.start()`'s
    /// doc comment). A no-op (beyond `containers.start()`, itself a no-op on
    /// the `runtimeMissing` path) if construction hit `runtimeMissing`.
    public func start() async {
        await containers.start()
        await poller?.start()
    }

    /// Idempotent and safe to call whether or not `start()` was ever called.
    public func stop() async {
        await poller?.stop()
        containers.stop()
    }
}
