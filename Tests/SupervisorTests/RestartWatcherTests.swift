import ContainerClient
import ContainerClientTestSupport
import Supervisor
import Testing

private actor SupervisorEventRecorder {
    private(set) var values: [SupervisorEvent] = []

    func append(_ value: SupervisorEvent) {
        values.append(value)
    }
}

@Test func alwaysPolicyRestartsStoppedContainerThroughPollerEvent() async {
    let runtime = FakeContainerRuntime()
    let coordinator = RestartCoordinator(services: [
        .init(service: "api", containerID: "payments-api-1", policy: .always),
    ])
    let watcher = RestartWatcher(runtime: runtime, coordinator: coordinator, sleep: { _ in })
    let recorder = SupervisorEventRecorder()
    let (events, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)

    continuation.yield(.containerStateChanged(
        ContainerSummary(
            id: "payments-api-1",
            status: "stopped",
            imageReference: "demo/api:latest",
            addresses: []
        ),
        previousStatus: "running"
    ))
    continuation.finish()
    await watcher.run(events: events) { event in
        await recorder.append(event)
    }

    #expect(await runtime.calls.contains(.startContainer(id: "payments-api-1")))
    #expect(await recorder.values == [
        .restartScheduled(service: "api", containerID: "payments-api-1", delay: .milliseconds(100)),
        .restarted(service: "api", containerID: "payments-api-1"),
    ])
    let snapshot = await coordinator.snapshot()
    #expect(snapshot.services["api"]?.attempts == 1)
}

@Test func onFailurePolicyWarnsWhenRuntimeExitStatusIsUnavailable() async {
    let runtime = FakeContainerRuntime()
    let coordinator = RestartCoordinator(services: [
        .init(service: "worker", containerID: "payments-worker-1", policy: .onFailure(maxRetries: 3)),
    ])
    let watcher = RestartWatcher(runtime: runtime, coordinator: coordinator, sleep: { _ in })
    let recorder = SupervisorEventRecorder()
    let (events, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)

    continuation.yield(.containerStateChanged(
        ContainerSummary(
            id: "payments-worker-1",
            status: "stopped",
            imageReference: "demo/worker:latest",
            addresses: []
        ),
        previousStatus: "running"
    ))
    continuation.finish()
    await watcher.run(events: events) { event in await recorder.append(event) }

    #expect(!(await runtime.calls.contains(.startContainer(id: "payments-worker-1"))))
    let recordedEvents = await recorder.values
    #expect(recordedEvents.count == 1)
    guard case .warning(let service, let message) = recordedEvents.first else {
        Issue.record("expected an explicit exit-status warning")
        return
    }
    #expect(service == "worker")
    #expect(message.contains("does not expose"))
}
