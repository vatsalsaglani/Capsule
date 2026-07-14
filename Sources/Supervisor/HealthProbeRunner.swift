import ContainerClient
import Foundation

public struct HealthProbeObservation: Sendable, Codable, Equatable {
    public let state: HealthState
    public let attempt: Int
    public let output: String

    public init(state: HealthState, attempt: Int, output: String) {
        self.state = state
        self.attempt = attempt
        self.output = output
    }
}

public enum HealthProbeError: Error, Sendable, Equatable {
    case unhealthy(containerID: String, lastOutput: String)
}

extension HealthProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unhealthy(let containerID, let lastOutput):
            let detail = lastOutput.isEmpty ? "probe produced no output" : lastOutput
            return "container \(containerID) is unhealthy after its configured retries: \(detail)"
        }
    }
}

/// Executes one service's healthcheck and owns no UI state. The injected
/// sleeper keeps the state machine deterministic in tests and lets a future
/// LaunchAgent use the exact same actor.
public actor HealthProbeRunner {
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

    /// Waits until the probe succeeds or the retry budget is exhausted.
    /// Probes begin immediately during `startPeriod`: an early success wins,
    /// while failures observed before the grace deadline remain `.starting`
    /// and do not consume `retries`. `attempt` is the total probe number, not
    /// the number of retry-budget failures.
    public func waitUntilHealthy(
        containerID: String,
        plan: HealthcheckPlan,
        onObservation: @Sendable (HealthProbeObservation) async throws -> Void = { _ in }
    ) async throws -> HealthProbeObservation {
        try Task.checkCancellation()
        let startedAt = await now()
        let allowedFailures = max(plan.retries, 1)
        var countedFailures = 0
        var probeNumber = 0
        var lastOutput = ""

        while true {
            try Task.checkCancellation()
            probeNumber += 1
            let succeeded: Bool
            do {
                let result = try await runtime.exec(
                    id: containerID,
                    argv: plan.argv,
                    timeout: plan.timeout
                )
                lastOutput = Self.output(from: result)
                succeeded = result.exitCode == 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A timed-out or otherwise failed probe is a healthcheck
                // failure, not a supervisor failure. It consumes the same
                // retry budget as a non-zero probe exit.
                lastOutput = error.localizedDescription
                succeeded = false
            }
            if succeeded {
                let observation = HealthProbeObservation(
                    state: .healthy,
                    attempt: probeNumber,
                    output: lastOutput
                )
                try await onObservation(observation)
                return observation
            }

            let currentTime = await now()
            let elapsed = startedAt.duration(to: currentTime)
            let isInStartPeriod = elapsed < plan.startPeriod
            if !isInStartPeriod {
                countedFailures += 1
            }
            let exhausted = !isInStartPeriod && countedFailures >= allowedFailures
            let state: HealthState = exhausted ? .unhealthy : .starting
            try await onObservation(.init(state: state, attempt: probeNumber, output: lastOutput))
            if exhausted {
                throw HealthProbeError.unhealthy(containerID: containerID, lastOutput: lastOutput)
            }

            try await sleep(plan.interval)
        }
    }

    static func output(from result: ExecResult) -> String {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
