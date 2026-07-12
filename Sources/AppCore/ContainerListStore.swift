import ContainerClient
import EventBus
import Foundation
import Observation

/// The testable state machine behind the Containers screen (AGENTS.md rule
/// 1 — every feature must be drivable from a unit test against CapsuleKit,
/// not a View/ViewModel). Subscribes to one `EventBus<RuntimeEvent>` and
/// folds each event into `phase`; every mutating action is a thin pass-
/// through to the injected `ContainerRuntime` with failures captured as
/// `lastActionError` instead of thrown, so a View can bind to state instead
/// of catching errors itself.
///
/// No SwiftUI import here (P1B B1 hard rule) — `swift test` exercises this
/// headless, standing in for the GUI smoke test until the app layer wires it
/// up in a later batch.
@MainActor
@Observable
public final class ContainerListStore {
    public enum Phase: Equatable {
        /// Constructed but `start()` hasn't produced a first snapshot yet.
        case connecting
        /// The runtime couldn't even be constructed (e.g. `container` binary
        /// not found). Deep onboarding is P1D's boundary — this only carries
        /// honest install-guidance copy to render, nothing more.
        case runtimeMissing(message: String)
        /// The runtime was reachable but the poller's last tick failed.
        /// `lastKnown` keeps the prior list visible rather than blanking the
        /// screen on a transient outage.
        case unavailable(message: String, lastKnown: [ContainerSummary])
        case loaded([ContainerSummary])
    }

    public struct ActionError: Equatable, Sendable {
        /// `nil` for actions that aren't scoped to a single container (e.g.
        /// a partial failure inside `stopAllRunning`'s loop is still
        /// attributed to the specific id that failed, so this is only `nil`
        /// in practice for future non-id-scoped actions).
        public let id: String?
        public let message: String

        public init(id: String?, message: String) {
            self.id = id
            self.message = message
        }
    }

    public private(set) var phase: Phase
    public private(set) var lastActionError: ActionError?

    private let runtime: (any ContainerRuntime)?
    private let events: EventBus<RuntimeEvent>?
    /// `nonisolated(unsafe)`: `deinit` is itself nonisolated by language
    /// rule and needs to cancel this task; plain `nonisolated` isn't legal
    /// on a mutable stored property under the `@Observable` macro
    /// expansion (compiler steers here explicitly). Safe in practice: every
    /// other read/write happens on the main actor (`start()`/`stop()`),
    /// `deinit` runs only once every other reference to `self` is already
    /// gone (nothing left to race against), and `Task.cancel()` itself is
    /// safe to call from any context. `@ObservationIgnored` because this is
    /// implementation plumbing, not view-observable state, and the
    /// `@Observable` macro's own property-wrapping otherwise conflicts with
    /// `nonisolated(unsafe)` on a mutable stored property.
    @ObservationIgnored
    private nonisolated(unsafe) var subscriptionTask: Task<Void, Never>?

    /// Real pipeline: an `events` bus fed by a `RuntimePoller` somewhere
    /// upstream (owned by `RuntimeSession`), and a `runtime` (typically a
    /// `RuntimeGateway`) to drive actions through.
    public init(runtime: any ContainerRuntime, events: EventBus<RuntimeEvent>) {
        self.runtime = runtime
        self.events = events
        self.phase = .connecting
    }

    /// Degraded construction path: the runtime couldn't be built at all
    /// (e.g. `RuntimeError.binaryNotFound`). There is nothing to subscribe to
    /// or act through — `start()`/`stop()` are no-ops and every action is a
    /// no-op, since there's no `runtime` to call.
    public init(runtimeMissingMessage message: String) {
        self.runtime = nil
        self.events = nil
        self.phase = .runtimeMissing(message: message)
    }

    deinit {
        subscriptionTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Idempotent: calling twice while already subscribed is a no-op. A
    /// no-op on the `runtimeMissing` construction path too (no `events` to
    /// subscribe to).
    ///
    /// **Why `async`:** `events.subscribe()` is awaited *here*, synchronously
    /// with respect to the caller, before the drain-only `Task` is spawned —
    /// not inside that `Task`. If the subscribe were deferred into the
    /// unstructured `Task` (racing against whatever starts the poller right
    /// after `start()` returns), the poller's very first tick could publish
    /// its `.snapshot` before this store's continuation is registered on the
    /// bus, silently dropping that snapshot forever (`EventBus.publish`
    /// doesn't replay/buffer for late subscribers) and leaving the store
    /// stuck in `.connecting`. Awaiting the subscribe before returning
    /// guarantees "subscribed" happens-before "caller may now start
    /// producing," matching the same discipline `RuntimePollerTests`'
    /// `makeCollector` helper already uses for exactly this reason.
    ///
    /// **Accepted residual reentrancy edge case:** because `start()`
    /// suspends at `await events.subscribe()`, calling `stop()` from another
    /// caller *during* that suspension (actor reentrancy — `self` is
    /// `@MainActor`, not a fully serial queue across `await` points) sees
    /// `subscriptionTask == nil` and no-ops, then `start()` resumes and
    /// installs the task anyway. `RuntimeSession` never does this (`start()`
    /// and `stop()` are only ever awaited sequentially, never raced against
    /// each other), so this is a deliberate scope cut rather than a fix
    /// applied — same accepted-residual-race posture as `RuntimeGateway`'s
    /// `pullImage`/`deleteImage` doc comment.
    public func start() async {
        guard let events, subscriptionTask == nil else { return }
        let stream = await events.subscribe()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
    }

    /// Idempotent and safe to call whether or not `start()` was ever called.
    /// Cancelling relies on `AsyncStream.Continuation.onTermination` firing
    /// on the *consuming* task's cancellation (not just on `finish()`), which
    /// unsubscribes this store's stream from the bus — no leaked
    /// continuation, no leaked `Task` keeping the store alive.
    public func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    // MARK: - Derived state

    public var runningCount: Int {
        currentList.filter { $0.runState == .running }.count
    }

    private var currentList: [ContainerSummary] {
        switch phase {
        case .connecting, .runtimeMissing:
            return []
        case .unavailable(_, let lastKnown):
            return lastKnown
        case .loaded(let containers):
            return containers
        }
    }

    public func dismissActionError() {
        lastActionError = nil
    }

    // MARK: - Actions

    public func startContainer(id: String) async {
        await perform(id: id) { try await $0.startContainer(id: id) }
    }

    public func stopContainer(id: String) async {
        await perform(id: id) { try await $0.stopContainer(id: id, timeoutSeconds: nil) }
    }

    public func killContainer(id: String, signal: String) async {
        await perform(id: id) { try await $0.killContainer(id: id, signal: signal) }
    }

    /// Stop-then-start composition. Lives here (not in a View) so it's
    /// unit-tested against the fake runtime rather than eyeballed in the UI.
    /// If the stop fails, the start is not attempted — the recorded action
    /// error reflects the stop failure.
    public func restartContainer(id: String) async {
        await perform(id: id) { runtime in
            try await runtime.stopContainer(id: id, timeoutSeconds: nil)
            try await runtime.startContainer(id: id)
        }
    }

    public func deleteContainer(id: String, force: Bool) async {
        await perform(id: id) { try await $0.deleteContainer(id: id, force: force) }
    }

    /// Stops every currently-running container, one at a time in id order.
    /// A failure on one id is recorded as `lastActionError` and does not
    /// prevent the remaining ids from being attempted.
    public func stopAllRunning() async {
        guard let runtime else { return }
        let runningIDs = currentList.filter { $0.runState == .running }.map(\.id)
        for id in runningIDs {
            do {
                try await runtime.stopContainer(id: id, timeoutSeconds: nil)
            } catch {
                setActionError(id: id, error: error)
            }
        }
    }

    private func perform(id: String, _ operation: (any ContainerRuntime) async throws -> Void) async {
        guard let runtime else { return }
        do {
            try await operation(runtime)
        } catch {
            setActionError(id: id, error: error)
        }
    }

    private func setActionError(id: String?, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        lastActionError = ActionError(id: id, message: message)
    }

    // MARK: - Event → state mapping

    private func apply(_ event: RuntimeEvent) {
        switch event {
        case .snapshot(let containers):
            phase = .loaded(containers.sorted { $0.id < $1.id })
        case .containerAdded(let summary):
            insertSorted(summary)
        case .containerRemoved(let id):
            removeByID(id)
        case .containerStateChanged(let summary, previousStatus: _):
            replace(summary)
        case .runtimeBecameUnavailable(let message):
            phase = .unavailable(message: message, lastKnown: currentList)
        case .runtimeBecameAvailable:
            // No-op by design: the poller's contract guarantees an
            // immediate follow-up `.snapshot` after every
            // `.runtimeBecameAvailable`, which is what actually repopulates
            // `phase` — see `RuntimeEvent.runtimeBecameAvailable`'s doc
            // comment.
            break
        }
    }

    private func insertSorted(_ summary: ContainerSummary) {
        var list = currentList
        if let index = list.firstIndex(where: { $0.id == summary.id }) {
            list[index] = summary
        } else if let insertionIndex = list.firstIndex(where: { $0.id > summary.id }) {
            list.insert(summary, at: insertionIndex)
        } else {
            list.append(summary)
        }
        phase = .loaded(list)
    }

    private func removeByID(_ id: String) {
        var list = currentList
        list.removeAll { $0.id == id }
        phase = .loaded(list)
    }

    private func replace(_ summary: ContainerSummary) {
        insertSorted(summary)
    }
}
