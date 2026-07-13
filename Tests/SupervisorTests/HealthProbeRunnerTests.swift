import ContainerClient
import ContainerClientTestSupport
import Foundation
import Supervisor
import Testing

private actor ObservationRecorder {
    private(set) var values: [HealthProbeObservation] = []

    func append(_ value: HealthProbeObservation) {
        values.append(value)
    }
}

private actor ManualHealthProbeClock {
    private var instant = ContinuousClock.now

    func current() -> ContinuousClock.Instant { instant }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
    }
}

@Test func healthyProbeReturnsOutputAndExecutesConfiguredArgv() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setExecResult(
        ExecResult(exitCode: 0, stdout: Data("ready\n".utf8), stderr: Data()),
        forID: "payments-api-1"
    )
    let runner = HealthProbeRunner(runtime: runtime, sleep: { _ in })
    let observation = try await runner.waitUntilHealthy(
        containerID: "payments-api-1",
        plan: HealthcheckPlan(
            argv: ["wget", "-q", "localhost/health"],
            interval: .seconds(1),
            timeout: .seconds(2),
            retries: 3
        )
    )

    #expect(observation == .init(state: .healthy, attempt: 1, output: "ready"))
    #expect(await runtime.calls == [
        .exec(
            id: "payments-api-1",
            argv: ["wget", "-q", "localhost/health"],
            timeout: .seconds(2)
        ),
    ])
}

@Test func unhealthyProbePublishesEachAttemptAndFailsWithLastOutput() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setExecResult(
        ExecResult(exitCode: 1, stdout: Data(), stderr: Data("connection refused\n".utf8)),
        forID: "payments-db-1"
    )
    let recorder = ObservationRecorder()
    let runner = HealthProbeRunner(runtime: runtime, sleep: { _ in })

    await #expect(throws: HealthProbeError.self) {
        try await runner.waitUntilHealthy(
            containerID: "payments-db-1",
            plan: HealthcheckPlan(
                argv: ["pg_isready"],
                interval: .zero,
                timeout: .seconds(1),
                retries: 2
            ),
            onObservation: { observation in
                await recorder.append(observation)
            }
        )
    }

    #expect(await recorder.values == [
        .init(state: .starting, attempt: 1, output: "connection refused"),
        .init(state: .unhealthy, attempt: 2, output: "connection refused"),
    ])
}

@Test func healthProbeRunsDuringStartPeriodAndReturnsOnEarlySuccess() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setExecResult(
        ExecResult(exitCode: 1, stdout: Data(), stderr: Data("warming up".utf8)),
        forID: "payments-api-1"
    )
    let clock = ManualHealthProbeClock()
    let recorder = ObservationRecorder()
    let runner = HealthProbeRunner(
        runtime: runtime,
        sleep: { duration in
            await clock.advance(by: duration)
            await runtime.setExecResult(
                ExecResult(exitCode: 0, stdout: Data("ready".utf8), stderr: Data()),
                forID: "payments-api-1"
            )
        },
        now: { await clock.current() }
    )

    let observation = try await runner.waitUntilHealthy(
        containerID: "payments-api-1",
        plan: HealthcheckPlan(
            argv: ["check-health"],
            interval: .seconds(2),
            timeout: .seconds(1),
            retries: 1,
            startPeriod: .seconds(10)
        ),
        onObservation: { observation in
            await recorder.append(observation)
        }
    )

    #expect(observation == .init(state: .healthy, attempt: 2, output: "ready"))
    #expect(await recorder.values == [
        .init(state: .starting, attempt: 1, output: "warming up"),
        .init(state: .healthy, attempt: 2, output: "ready"),
    ])
    #expect(await runtime.calls.count == 2)
}

@Test func startPeriodFailuresDoNotConsumeHealthRetryBudget() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setExecResult(
        ExecResult(exitCode: 1, stdout: Data(), stderr: Data("not ready".utf8)),
        forID: "payments-db-1"
    )
    let clock = ManualHealthProbeClock()
    let recorder = ObservationRecorder()
    let runner = HealthProbeRunner(
        runtime: runtime,
        sleep: { duration in await clock.advance(by: duration) },
        now: { await clock.current() }
    )

    await #expect(throws: HealthProbeError.self) {
        try await runner.waitUntilHealthy(
            containerID: "payments-db-1",
            plan: HealthcheckPlan(
                argv: ["pg_isready"],
                interval: .seconds(2),
                timeout: .seconds(1),
                retries: 2,
                startPeriod: .seconds(5)
            ),
            onObservation: { observation in
                await recorder.append(observation)
            }
        )
    }

    #expect(await recorder.values == [
        .init(state: .starting, attempt: 1, output: "not ready"), // t=0, grace
        .init(state: .starting, attempt: 2, output: "not ready"), // t=2, grace
        .init(state: .starting, attempt: 3, output: "not ready"), // t=4, grace
        .init(state: .starting, attempt: 4, output: "not ready"), // t=6, counted failure 1
        .init(state: .unhealthy, attempt: 5, output: "not ready"), // t=8, counted failure 2
    ])
    #expect(await runtime.calls.count == 5)
}
