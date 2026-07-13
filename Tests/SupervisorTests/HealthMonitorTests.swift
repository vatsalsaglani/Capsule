import ContainerClient
import ContainerClientTestSupport
import Foundation
import Supervisor
import Testing

private actor ContinuousHealthRecorder {
    private(set) var values: [HealthProbeObservation] = []
    func append(_ value: HealthProbeObservation) { values.append(value) }
}

private actor MonitorStepCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

@Test func continuousHealthMonitorFlapsAfterConsecutiveFailureThreshold() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setExecResult(
        ExecResult(exitCode: 0, stdout: Data("ready".utf8), stderr: Data()),
        forID: "demo-api-1"
    )
    let recorder = ContinuousHealthRecorder()
    let steps = MonitorStepCounter()
    let monitor = HealthMonitor(runtime: runtime, sleep: { _ in
        switch await steps.next() {
        case 1, 2:
            await runtime.setExecResult(
                ExecResult(exitCode: 1, stdout: Data(), stderr: Data("down".utf8)),
                forID: "demo-api-1"
            )
        case 3:
            await runtime.setExecResult(
                ExecResult(exitCode: 0, stdout: Data("back".utf8), stderr: Data()),
                forID: "demo-api-1"
            )
        default:
            throw CancellationError()
        }
    })

    await #expect(throws: CancellationError.self) {
        try await monitor.run(
            containerID: "demo-api-1",
            plan: HealthcheckPlan(
                argv: ["check"],
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
        .init(state: .healthy, attempt: 1, output: "ready"),
        .init(state: .healthy, attempt: 2, output: "down"),
        .init(state: .unhealthy, attempt: 3, output: "down"),
        .init(state: .healthy, attempt: 4, output: "back"),
    ])
}
