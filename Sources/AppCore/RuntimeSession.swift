import ContainerClient
import EventBus
import Foundation
import Observation
import TerminalKit

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
    /// Same `RuntimeGateway` `containers` was built on top of — shared, not
    /// re-wrapped, so `makeDetailStore()` never spins up a second gateway
    /// layer. `nil` exactly when construction hit the `runtimeMissing` path.
    private let runtime: (any ContainerRuntime)?
    /// Same bus `containers`/`poller` share — reused by every
    /// `ContainerDetailStore` this session builds (one bus per session, per
    /// this type's "construct once, share everywhere" contract).
    private let events: EventBus<RuntimeEvent>

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
        self.events = events
        do {
            let base = try makeRuntime()
            let gateway = RuntimeGateway(base: base)
            self.runtime = gateway
            self.poller = RuntimePoller(
                runtime: gateway,
                events: events,
                interval: pollInterval,
                idleInterval: idleInterval,
                unavailableInterval: unavailableInterval
            )
            self.containers = ContainerListStore(runtime: gateway, events: events)
        } catch {
            self.runtime = nil
            self.poller = nil
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self.containers = ContainerListStore(runtimeMissingMessage: message)
        }
        self.menuBar = MenuBarStore(containers: self.containers)
    }

    /// Builds a fresh `ContainerDetailStore` bound to the same shared
    /// runtime + event bus as `containers` — never a second poller/bus for
    /// the same reason `MenuBarStore` derives from `containers` rather than
    /// re-subscribing. `nil` exactly when construction hit the
    /// `.runtimeMissing` path, matching `containers`' permanently-empty list
    /// there (nothing to ever select or inspect). Call once per inspector
    /// panel instance; the view drives its lifecycle via
    /// `activate(id:)`/`deactivate()`.
    public func makeDetailStore() -> ContainerDetailStore? {
        guard let runtime else { return nil }
        return ContainerDetailStore(runtime: runtime, events: events)
    }

    /// Builds a fresh `ImagesStore` bound to the same shared runtime as
    /// `containers`. `ImagesStore` has no event-bus subscription of its own
    /// (no `RuntimeEvent` case exists for image list changes — it's
    /// deliberately on-demand, see its doc comment), so unlike
    /// `makeDetailStore()` there's no `events` to pass. `nil` exactly when
    /// construction hit the `.runtimeMissing` path — nothing to list.
    public func makeImagesStore() -> ImagesStore? {
        guard let runtime else { return nil }
        return ImagesStore(runtime: runtime)
    }

    /// Builds a fresh `SystemStore` bound to the same shared runtime as
    /// `containers`, same on-demand posture as `makeImagesStore()`. `nil`
    /// exactly when construction hit the `.runtimeMissing` path.
    public func makeSystemStore() -> SystemStore? {
        guard let runtime else { return nil }
        return SystemStore(runtime: runtime)
    }

    /// Builds a fresh `TerminalSessionManager` (P1C) bound to the same
    /// shared runtime as `containers` (for `ShellDetector`'s non-interactive
    /// probes) and a `PTYExecSession` factory over the same `container`
    /// binary the runtime itself resolved at startup. Re-locates the binary
    /// path independently via `ContainerBinaryLocator` rather than reading
    /// it off `runtime` — `ContainerRuntime` deliberately doesn't expose its
    /// backing binary path (P1A contract), and the interactive PTY exec
    /// doesn't go through the protocol at all (S3: it needs direct
    /// master-fd/pid control for cooperative terminate), only the shell
    /// probes do. `nil` exactly when construction hit the `.runtimeMissing`
    /// path (nothing to open a terminal into) or the binary can no longer
    /// be located.
    public func makeTerminalSessionManager() -> TerminalSessionManager? {
        guard let runtime else { return nil }
        guard let binaryPath = ContainerBinaryLocator.locate() else { return nil }
        return TerminalSessionManager(
            runtime: runtime,
            makeSession: PTYExecSession.makeContainerExecFactory(binaryPath: binaryPath)
        )
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
