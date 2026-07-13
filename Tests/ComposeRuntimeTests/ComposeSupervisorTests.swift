import ComposeRuntime
import ComposeSpec
import ContainerClient
import ContainerClientTestSupport
import Foundation
import ProjectStore
import Testing

private actor SupervisionSnapshotRecorder {
    private(set) var values: [ComposeSupervisionSnapshot] = []
    func append(_ value: ComposeSupervisionSnapshot) { values.append(value) }
}

private func makeSupervisionFixture(
    yaml: String,
    state: StoredProjectState
) throws -> (ProjectStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ProjectStore(rootDirectory: root)
    let source = ComposeSource(
        yaml: yaml,
        fallbackName: "demo",
        workingDirectory: root.path,
        filePath: root.appendingPathComponent("compose.yaml").path
    )
    let document = try ComposeParser().parse(source: source)
    try store.saveProject(ProjectRecord(
        id: document.projectName,
        name: document.projectName,
        sourcePath: source.filePath ?? root.path,
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    try store.saveResolvedProject(document, projectID: document.projectName)
    try store.saveState(state, projectID: document.projectName)
    return (store, root)
}

private func supervisionEventually(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

@Test func supervisorRestoresHistoricalHealthThenPersistsLiveProbeAfterRelaunch() async throws {
    let state = StoredProjectState(
        revision: "revision",
        desiredRunning: true,
        serviceConfigHashes: ["api": "hash"],
        services: [
            "api": StoredServiceState(
                containerID: "demo-api-1",
                desiredRunning: true,
                healthObservation: StoredHealthObservation(
                    state: .unhealthy,
                    attempt: 4,
                    output: "old failure",
                    observedAt: Date(timeIntervalSince1970: 10)
                )
            ),
        ]
    )
    let (store, root) = try makeSupervisionFixture(yaml: """
    name: demo
    services:
      api:
        image: api
        healthcheck:
          test: ["CMD", "check"]
          interval: 1h
    """, state: state)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = FakeContainerRuntime()
    let container = ContainerSummary(
        id: "demo-api-1",
        status: "running",
        imageReference: "api",
        addresses: [],
        labels: [
            "capsule.project": "demo",
            "capsule.service": "api",
            "capsule.index": "1",
            "capsule.config-hash": "hash",
        ]
    )
    await runtime.setContainers([container])
    await runtime.setExecResult(
        ExecResult(exitCode: 0, stdout: Data("ready".utf8), stderr: Data()),
        forID: container.id
    )
    let recorder = SupervisionSnapshotRecorder()
    let supervisor = ComposeSupervisor(runtime: runtime, store: store)
    let (events, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)
    let task = Task {
        try await supervisor.run(events: events) { snapshot in
            await recorder.append(snapshot)
        }
    }

    continuation.yield(.snapshot([container]))
    #expect(await supervisionEventually {
        await recorder.values.contains { snapshot in
            snapshot.projects.first?.services.first?.health?.isLive == true
        }
    })
    let snapshots = await recorder.values
    #expect(snapshots.contains { snapshot in
        let health = snapshot.projects.first?.services.first?.health
        return health?.state == .unhealthy && health?.isLive == false
    })
    let persisted = try store.loadState(projectID: "demo").services["api"]?.healthObservation
    #expect(persisted?.state == .healthy)
    #expect(persisted?.attempt == 1)
    #expect(persisted?.output == "ready")

    continuation.finish()
    _ = try await task.value
}

@Test func supervisorResumesAlwaysRestartPolicyFromAuthoritativeRelaunchSnapshot() async throws {
    let state = StoredProjectState(
        revision: "revision",
        desiredRunning: true,
        serviceConfigHashes: ["worker": "hash"],
        services: [
            "worker": StoredServiceState(
                containerID: "demo-worker-1",
                desiredRunning: true
            ),
        ]
    )
    let (store, root) = try makeSupervisionFixture(yaml: """
    name: demo
    services:
      worker:
        image: worker
        restart: always
    """, state: state)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = FakeContainerRuntime()
    let container = ContainerSummary(
        id: "demo-worker-1",
        status: "stopped",
        imageReference: "worker",
        addresses: [],
        labels: [
            "capsule.project": "demo",
            "capsule.service": "worker",
            "capsule.index": "1",
            "capsule.config-hash": "hash",
        ]
    )
    await runtime.setContainers([container])
    let supervisor = ComposeSupervisor(runtime: runtime, store: store)
    let (events, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)
    let task = Task { try await supervisor.run(events: events) }

    continuation.yield(.snapshot([container]))
    #expect(await supervisionEventually {
        await runtime.calls.contains(.startContainer(id: container.id))
    })
    let persisted = try store.loadState(projectID: "demo").services["worker"]?.restart
    #expect(persisted?.attempts == 1)
    #expect(persisted?.scheduledFor == nil)
    #expect(persisted?.scheduledContainerID == nil)

    continuation.finish()
    _ = try await task.value
}

@Test func supervisorNeverGuessesOnFailureExitStatus() async throws {
    let state = StoredProjectState(
        revision: "revision",
        desiredRunning: true,
        serviceConfigHashes: ["worker": "hash"],
        services: [
            "worker": StoredServiceState(
                containerID: "demo-worker-1",
                desiredRunning: true
            ),
        ]
    )
    let (store, root) = try makeSupervisionFixture(yaml: """
    name: demo
    services:
      worker:
        image: worker
        restart: on-failure:3
    """, state: state)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = FakeContainerRuntime()
    let container = ContainerSummary(
        id: "demo-worker-1",
        status: "stopped",
        imageReference: "worker",
        addresses: [],
        labels: [
            "capsule.project": "demo",
            "capsule.service": "worker",
            "capsule.index": "1",
            "capsule.config-hash": "hash",
        ]
    )
    await runtime.setContainers([container])
    let recorder = SupervisionSnapshotRecorder()
    let supervisor = ComposeSupervisor(runtime: runtime, store: store)
    let (events, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)
    let task = Task {
        try await supervisor.run(events: events) { snapshot in
            await recorder.append(snapshot)
        }
    }

    continuation.yield(.snapshot([container]))
    #expect(await supervisionEventually {
        await recorder.values.contains { snapshot in
            snapshot.projects.first?.services.first?.restart.limitation == .exitStatusUnavailable
        }
    })
    #expect(!(await runtime.calls.contains(.startContainer(id: container.id))))
    #expect(try store.loadState(projectID: "demo")
        .services["worker"]?.restart.limitation == .exitStatusUnavailable)

    continuation.finish()
    _ = try await task.value
}
