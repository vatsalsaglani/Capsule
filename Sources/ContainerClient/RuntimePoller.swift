import EventBus
import Foundation

/// Polls `ContainerRuntime.listContainers(all:)` on an interval and
/// synthesizes `RuntimeEvent`s onto an `EventBus` (plan §2.1; P1A step 2,
/// "Poller → EventBus" — replaces the ViewModel's direct polling loop).
///
/// No UI imports, fully serializable state (rule 6, AGENTS.md) — this moves
/// into a LaunchAgent (`capsuled`) in v1.1 unchanged.
///
/// **Reentrancy discipline** (swift-concurrency-pro `actors.md`): every await
/// inside the poll loop is followed by a re-check of both `Task.isCancelled`
/// and a `generation` counter bumped by `stop()`/`start()`. A `stop()` that
/// lands while a tick is mid-flight (awaiting `listContainers`, awaiting an
/// `events.publish`, or asleep between ticks) must never let that stale tick
/// publish a leftover event afterward — the generation check makes every
/// resume point re-validate "is this still the run stop()/start() expects,"
/// not just "was cancel() ever called."
public actor RuntimePoller {
    private let runtime: any ContainerRuntime
    private let events: EventBus<RuntimeEvent>
    private let interval: Duration
    private let idleInterval: Duration
    private let unavailableInterval: Duration

    /// Consecutive unchanged ticks before backing off from `interval` to
    /// `idleInterval`. Any observed change resets the counter and the
    /// interval immediately.
    private let idleBackoffThreshold = 5

    private var pollTask: Task<Void, Never>?
    private var generation = 0

    public init(
        runtime: any ContainerRuntime,
        events: EventBus<RuntimeEvent>,
        interval: Duration = .seconds(2),
        idleInterval: Duration = .seconds(6),
        unavailableInterval: Duration = .seconds(5)
    ) {
        self.runtime = runtime
        self.events = events
        self.interval = interval
        self.idleInterval = idleInterval
        self.unavailableInterval = unavailableInterval
    }

    /// Idempotent: calling `start()` while already running is a no-op.
    public func start() {
        guard pollTask == nil else { return }
        generation += 1
        let runGeneration = generation
        pollTask = Task { [weak self] in
            await self?.pollLoop(generation: runGeneration)
        }
    }

    /// Idempotent and cancel-safe: safe to call whether or not `start()` was
    /// ever called, and safe to call more than once. Bumps `generation` so
    /// any tick already in flight observes the stop on its next check point
    /// and returns without publishing.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
    }

    private func pollLoop(generation runGeneration: Int) async {
        var previous: [String: ContainerSummary] = [:]
        var hasSucceededOnce = false
        var isUnavailable = false
        var unchangedTickCount = 0
        var currentInterval = interval

        while isCurrent(runGeneration) {
            do {
                let containers = try await runtime.listContainers(all: true)
                guard isCurrent(runGeneration) else { return }

                if isUnavailable || !hasSucceededOnce {
                    if isUnavailable {
                        isUnavailable = false
                        await events.publish(.runtimeBecameAvailable)
                        guard isCurrent(runGeneration) else { return }
                    }
                    await events.publish(.snapshot(containers))
                    guard isCurrent(runGeneration) else { return }
                    previous = Self.index(containers)
                    hasSucceededOnce = true
                    unchangedTickCount = 0
                    currentInterval = interval
                } else {
                    let changed = try await publishDiff(
                        current: containers,
                        previous: &previous,
                        generation: runGeneration
                    )
                    guard isCurrent(runGeneration) else { return }
                    if changed {
                        unchangedTickCount = 0
                        currentInterval = interval
                    } else {
                        unchangedTickCount += 1
                        if unchangedTickCount >= idleBackoffThreshold {
                            currentInterval = idleInterval
                        }
                    }
                }
            } catch is StoppedWhileAwaiting {
                return
            } catch {
                guard isCurrent(runGeneration) else { return }
                if !isUnavailable {
                    isUnavailable = true
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    await events.publish(.runtimeBecameUnavailable(message: message))
                }
            }

            guard isCurrent(runGeneration) else { return }
            let sleepDuration = isUnavailable ? unavailableInterval : currentInterval
            do {
                try await Task.sleep(for: sleepDuration)
            } catch {
                return
            }
        }
    }

    /// Diffs `current` against `previous`, publishing one event per observed
    /// change (added → changed → removed, in that order; removed ids sorted
    /// for determinism since dictionary key order is not guaranteed).
    /// Returns whether anything changed. Re-checks `generation`/cancellation
    /// between every publish so a `stop()` landing mid-diff halts immediately
    /// without emitting the remaining events for this tick.
    private func publishDiff(
        current: [ContainerSummary],
        previous: inout [String: ContainerSummary],
        generation runGeneration: Int
    ) async throws -> Bool {
        let currentByID = Self.index(current)
        var changed = false

        for summary in current {
            guard isCurrent(runGeneration) else { throw StoppedWhileAwaiting() }
            if let old = previous[summary.id] {
                if old.status != summary.status {
                    changed = true
                    await events.publish(.containerStateChanged(summary, previousStatus: old.status))
                }
            } else {
                changed = true
                await events.publish(.containerAdded(summary))
            }
        }

        for id in previous.keys.sorted() where currentByID[id] == nil {
            guard isCurrent(runGeneration) else { throw StoppedWhileAwaiting() }
            changed = true
            await events.publish(.containerRemoved(id: id))
        }

        previous = currentByID
        return changed
    }

    private func isCurrent(_ runGeneration: Int) -> Bool {
        !Task.isCancelled && generation == runGeneration
    }

    private static func index(_ containers: [ContainerSummary]) -> [String: ContainerSummary] {
        Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
    }

    private struct StoppedWhileAwaiting: Error {}
}
