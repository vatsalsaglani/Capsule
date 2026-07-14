import ContainerClient
import Foundation

/// Continuous Docker-style health monitoring for a running container. The
/// start period is applied once per monitor generation; successful probes
/// reset the consecutive-failure count, while later failures retain a healthy
/// state until the retry threshold is exhausted.
public struct HealthMonitor: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias Now = @Sendable () async -> ContinuousClock.Instant

    private let runtime: any ContainerRuntime
    private let sleep: Sleeper
    private let now: Now

    public init(
        runtime: any ContainerRuntime,
        sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) },
        now: @escaping Now = { ContinuousClock.now }
    ) {
        self.runtime = runtime
        self.sleep = sleep
        self.now = now
    }

    public func run(
        containerID: String,
        plan: HealthcheckPlan,
        onObservation: @escaping @Sendable (HealthProbeObservation) async throws -> Void
    ) async throws {
        let startedAt = await now()
        let allowedFailures = max(plan.retries, 1)
        var consecutiveFailures = 0
        var probeNumber = 0
        var hasBeenHealthy = false

        while true {
            try Task.checkCancellation()
            probeNumber += 1

            let succeeded: Bool
            let output: String
            do {
                let result = try await runtime.exec(
                    id: containerID,
                    argv: plan.argv,
                    timeout: plan.timeout
                )
                succeeded = result.exitCode == 0
                output = HealthProbeRunner.output(from: result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                succeeded = false
                output = error.localizedDescription
            }

            let state: HealthState
            if succeeded {
                consecutiveFailures = 0
                hasBeenHealthy = true
                state = .healthy
            } else {
                let currentTime = await now()
                let elapsed = startedAt.duration(to: currentTime)
                if elapsed < plan.startPeriod {
                    state = .starting
                } else {
                    consecutiveFailures += 1
                    state = consecutiveFailures >= allowedFailures
                        ? .unhealthy
                        : (hasBeenHealthy ? .healthy : .starting)
                }
            }

            try await onObservation(.init(
                state: state,
                attempt: probeNumber,
                output: output
            ))
            try await sleep(plan.interval)
        }
    }
}
