import ContainerClient
import EventBus
import Foundation
import Observation

/// One `stats(ids:)` tick, timestamped on receipt. `StatsSample` itself
/// carries no timestamp (spike S2 finding #9) — the real polling cadence is
/// ~4.2s, not the nominal `statsInterval`
/// (`docs/learnings/2026-07-13-stats-polling-cost.md`), so CPU% derivation
/// needs the store's own wall-clock receipt time between ticks, not an
/// assumed fixed interval.
public struct StatsPoint: Sendable, Equatable {
    public let sample: StatsSample
    public let receivedAt: Date

    public init(sample: StatsSample, receivedAt: Date = Date()) {
        self.sample = sample
        self.receivedAt = receivedAt
    }
}

/// One plotted CPU% value, derived from a consecutive pair of `StatsPoint`s
/// (see `ContainerDetailStore.cpuPercent(current:previous:)`). `Identifiable`
/// via its own timestamp so a swift-charts `Chart(data)` init can consume it
/// directly.
public struct CPUPercentPoint: Sendable, Equatable, Identifiable {
    public var id: Date { at }
    public let at: Date
    public let percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

/// The testable state machine behind the Containers screen's inspector
/// panel (P1B B3 — AGENTS.md rule 1: every feature drivable from a unit test
/// against CapsuleKit, not a View). One instance is bound to at most one
/// selected container at a time via explicit `activate(id:)`/`deactivate()`
/// calls from the view (onAppear/onDisappear/selection change) — there is no
/// implicit "current selection" tracking here, matching `ContainerListStore`'s
/// posture of being a thin, explicitly-driven state machine rather than
/// owning navigation state itself.
///
/// No SwiftUI import here (mirrors `ContainerListStore`) — `swift test`
/// exercises this headless.
@MainActor
@Observable
public final class ContainerDetailStore {
    private let runtime: any ContainerRuntime
    private let events: EventBus<RuntimeEvent>

    public private(set) var currentID: String?
    public private(set) var detail: ContainerDetail?
    /// Set when `inspectContainer(id:)` fails; `detail` is left at its last
    /// good value (or `nil` if there never was one) rather than blanked, so
    /// a transient inspect failure doesn't flash the whole panel empty.
    public private(set) var detailError: String?
    /// Ring-buffered to the last ~2000 lines (P1B B3 spec) — an unbounded
    /// `follow: true` stream on a chatty container must not grow this
    /// without bound.
    public private(set) var logLines: [LogLine] = []
    /// Ring-buffered to the last ~30 ticks (P1B B3 spec) — a rolling sparkline
    /// window, not a full history.
    public private(set) var statsSeries: [StatsPoint] = []

    private let logRingBufferCap = 2000
    private let statsSeriesCap = 30
    private var statsVisible = false

    /// `nonisolated(unsafe)` for the same reason as `ContainerListStore`'s
    /// `subscriptionTask`: `deinit` is nonisolated by language rule and must
    /// be able to cancel these, and `@ObservationIgnored` plumbing doesn't
    /// coexist with plain `nonisolated` on a mutable stored property under
    /// the `@Observable` macro expansion. Every other read/write happens on
    /// the main actor; `deinit` runs only once nothing else references
    /// `self`, so there's nothing left to race against.
    @ObservationIgnored
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var logTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var statsTask: Task<Void, Never>?

    public init(runtime: any ContainerRuntime, events: EventBus<RuntimeEvent>) {
        self.runtime = runtime
        self.events = events
    }

    deinit {
        eventTask?.cancel()
        logTask?.cancel()
        statsTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Idempotent for the same id (a re-`activate(id:)` with no change is a
    /// no-op, not a fresh refresh+resubscribe). Activating a *different* id
    /// tears down the previous id's subscriptions first — this store only
    /// ever tracks one active container at a time.
    public func activate(id: String) async {
        guard currentID != id else { return }
        cancelAllTasks()
        currentID = id
        detail = nil
        detailError = nil
        logLines = []
        statsSeries = []
        statsVisible = false

        await refreshDetail()
        await subscribeToStateChanges(id: id)
        startLogConsumption(id: id)
    }

    /// Idempotent and safe to call whether or not `activate(id:)` was ever
    /// called. Cancels every in-flight consumption task (event subscription,
    /// log follow, stats poll) and clears all published state.
    public func deactivate() {
        cancelAllTasks()
        currentID = nil
        detail = nil
        detailError = nil
        logLines = []
        statsSeries = []
        statsVisible = false
    }

    /// Starts or cancels stats consumption based on whether the stats tab is
    /// currently visible (S4 discipline —
    /// `docs/learnings/2026-07-13-stats-polling-cost.md` recommendation 2:
    /// no payoff running the poll unwatched). A no-op if `visible` matches
    /// the current state, or if no container is active.
    public func setStatsVisible(_ visible: Bool) {
        guard visible != statsVisible else { return }
        statsVisible = visible
        if visible {
            startStatsConsumption()
        } else {
            statsTask?.cancel()
            statsTask = nil
        }
    }

    private func cancelAllTasks() {
        eventTask?.cancel()
        eventTask = nil
        logTask?.cancel()
        logTask = nil
        statsTask?.cancel()
        statsTask = nil
    }

    // MARK: - Detail refresh

    private func refreshDetail() async {
        guard let id = currentID else { return }
        do {
            let detail = try await runtime.inspectContainer(id: id)
            guard currentID == id else { return }
            self.detail = detail
            detailError = nil
        } catch {
            guard currentID == id else { return }
            detailError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Awaits the subscribe *before* spawning the consuming `Task`, matching
    /// `ContainerListStore.start()`'s discipline (see its doc comment) — a
    /// `containerStateChanged` published between `activate(id:)` returning
    /// and this store actually registering on the bus would otherwise be
    /// silently dropped (`EventBus.publish` doesn't replay for late
    /// subscribers).
    private func subscribeToStateChanges(id: String) async {
        let stream = await events.subscribe()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                if case .containerStateChanged(let summary, previousStatus: _) = event, summary.id == id {
                    await self.refreshDetail()
                }
            }
        }
    }

    // MARK: - Logs

    private func startLogConsumption(id: String) {
        logTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.runtime.logs(id: id, follow: true, tail: 200)
                for try await line in stream {
                    guard !Task.isCancelled else { return }
                    self.appendLogLine(line)
                }
            } catch {
                // Best-effort: a log stream failure (e.g. the container was
                // deleted while following) doesn't blank the rest of the
                // inspector — `detail`/`detailError` already carry the
                // user-facing signal for that.
            }
        }
    }

    private func appendLogLine(_ line: LogLine) {
        logLines.append(line)
        if logLines.count > logRingBufferCap {
            logLines.removeFirst(logLines.count - logRingBufferCap)
        }
    }

    // MARK: - Stats

    private func startStatsConsumption() {
        guard let id = currentID else { return }
        statsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.runtime.stats(ids: [id])
                for try await tick in stream {
                    guard !Task.isCancelled else { return }
                    guard let sample = tick.first(where: { $0.id == id }) ?? tick.first else { continue }
                    self.appendStatsSample(sample)
                }
            } catch {
                // Best-effort, same posture as log consumption above.
            }
        }
    }

    private func appendStatsSample(_ sample: StatsSample) {
        statsSeries.append(StatsPoint(sample: sample))
        if statsSeries.count > statsSeriesCap {
            statsSeries.removeFirst(statsSeries.count - statsSeriesCap)
        }
    }

    /// CPU% derived from every consecutive pair in `statsSeries` (one fewer
    /// point than `statsSeries` itself — the first tick has no predecessor to
    /// diff against). Recomputed on read rather than cached: `statsSeries` is
    /// capped at ~30 points, so this is cheap.
    public var cpuPercentSeries: [CPUPercentPoint] {
        guard statsSeries.count >= 2 else { return [] }
        return zip(statsSeries.dropFirst(), statsSeries).compactMap { current, previous in
            guard let percent = Self.cpuPercent(current: current, previous: previous) else { return nil }
            return CPUPercentPoint(at: current.receivedAt, percent: percent)
        }
    }

    // MARK: - Pure functions (unit-tested)

    /// Derives an open-in-browser URL from a published port mapping.
    /// `hostAddress` `nil` or `"0.0.0.0"` (all interfaces) resolves to
    /// `localhost`; any other bound address is used verbatim. `nil` for UDP
    /// mappings — no browser opens a UDP endpoint, so there's nothing honest
    /// to link to (rule 10, AGENTS.md).
    public func browserURL(for port: PortMapping) -> URL? {
        guard port.proto == .tcp else { return nil }
        let host: String
        if let hostAddress = port.hostAddress, hostAddress != "0.0.0.0" {
            host = hostAddress
        } else {
            host = "localhost"
        }
        return URL(string: "http://\(host):\(port.hostPort)")
    }

    /// CPU usage as a percentage of one core between two ticks.
    ///
    /// **`cpuUsageMicroseconds` is a cumulative, monotonically-increasing
    /// counter since container start** (verified live —
    /// `docs/learnings/2026-07-13-cpu-usage-usec-semantics.md` — against a
    /// CPU-pegging scratch container: three `stats` ticks ~7s apart showed
    /// the raw value growing by ~7.16M/7.06s and ~7.12M/7.16s, both ≈100% of
    /// one core, matching the workload and ruling out "already a rate").
    /// Percentage is expressed per-core (Activity-Monitor convention — a
    /// fully-pegged 4-core container can read up to ~400%), not normalized
    /// to a 100% cap the way Docker's `nproc`-scaled figure is.
    ///
    /// Returns `nil` (no plotted point, rather than a nonsensical value) when
    /// the elapsed wall time isn't positive, or when the counter went
    /// backwards (e.g. the container restarted between ticks, resetting its
    /// cgroup counters).
    public nonisolated static func cpuPercent(current: StatsPoint, previous: StatsPoint) -> Double? {
        let elapsedSeconds = current.receivedAt.timeIntervalSince(previous.receivedAt)
        guard elapsedSeconds > 0 else { return nil }
        guard current.sample.cpuUsageMicroseconds >= previous.sample.cpuUsageMicroseconds else { return nil }
        let deltaSeconds = Double(current.sample.cpuUsageMicroseconds - previous.sample.cpuUsageMicroseconds) / 1_000_000
        return (deltaSeconds / elapsedSeconds) * 100
    }
}
