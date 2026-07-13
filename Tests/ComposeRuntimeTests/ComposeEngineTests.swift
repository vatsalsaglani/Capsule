import ComposePlanner
import ComposeRuntime
import ComposeSpec
import ContainerClient
import ContainerClientTestSupport
import Foundation
import ProjectStore
import Testing

private func temporaryStore() throws -> (ProjectStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (ProjectStore(rootDirectory: root), root)
}

private func source(_ yaml: String, directory: URL) -> ComposeSource {
    ComposeSource(
        yaml: yaml,
        fallbackName: "demo",
        workingDirectory: directory.path,
        filePath: directory.appendingPathComponent("custom-stack.yaml").path
    )
}

@Test func publicComposeExecPreservesConfiguredContainerUser() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([ContainerSummary(
        id: "demo-admin-1",
        status: "running",
        imageReference: "adminer:latest",
        addresses: [],
        labels: [
            "capsule.project": "demo",
            "capsule.service": "admin",
            "capsule.index": "1",
        ]
    )])
    await runtime.setExecResult(
        ExecResult(exitCode: 0, stdout: Data("configured-user\n".utf8), stderr: Data()),
        forID: "demo-admin-1"
    )
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      admin:
        image: adminer:latest
        user: "1000"
    """, directory: root))

    let result = try await project.exec(service: "admin", argv: ["id", "-u"])
    let calls = await runtime.calls

    #expect(result.stdoutText == "configured-user\n")
    #expect(calls.contains(.exec(
        id: "demo-admin-1",
        argv: ["id", "-u"],
        timeout: .seconds(60)
    )))
    #expect(!calls.contains { call in
        if case .execWithOptions = call { true } else { false }
    })
}

@Test func projectLogsFollowRunningServicesAndReadStoppedServiceTailWithoutFollowing() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([
        ContainerSummary(
            id: "demo-api-1",
            status: "running",
            imageReference: "alpine",
            addresses: [],
            labels: ["capsule.project": "demo", "capsule.service": "api", "capsule.index": "1"]
        ),
        ContainerSummary(
            id: "demo-worker-1",
            status: "stopped",
            imageReference: "alpine",
            addresses: [],
            labels: ["capsule.project": "demo", "capsule.service": "worker", "capsule.index": "1"]
        ),
    ])
    await runtime.setLogLines([LogLine(text: "api-ready")], forID: "demo-api-1")
    await runtime.setLogLines([LogLine(text: "worker-exited")], forID: "demo-worker-1")
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      api: { image: alpine }
      worker: { image: alpine }
    """, directory: root))

    var lines: [ProjectLogEntry] = []
    for try await line in try await project.logs(ProjectLogQuery(follow: true, tail: 200)) {
        lines.append(line)
    }

    #expect(Set(lines.map(\.line.text)) == ["api-ready", "worker-exited"])
    let calls = await runtime.calls
    #expect(calls.contains(.logs(id: "demo-api-1", follow: true, tail: 200)))
    #expect(calls.contains(.logs(id: "demo-worker-1", follow: false, tail: 200)))
}

@Test func downPreviewMatchesCapsuleOwnedResourcesAndExcludesUnconfiguredOrphans() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([
        ContainerSummary(
            id: "demo-api-1",
            status: "running",
            imageReference: "alpine",
            addresses: [],
            labels: ["capsule.project": "demo", "capsule.service": "api"]
        ),
        ContainerSummary(
            id: "demo-old-1",
            status: "stopped",
            imageReference: "alpine",
            addresses: [],
            labels: ["capsule.project": "demo", "capsule.service": "old"]
        ),
        ContainerSummary(
            id: "other-api-1",
            status: "running",
            imageReference: "alpine",
            addresses: [],
            labels: ["capsule.project": "other", "capsule.service": "api"]
        ),
    ])
    await runtime.setNetworks([
        NetworkSummary(name: "demo_default", labels: ["capsule.project": "demo"]),
        NetworkSummary(name: "other_default", labels: ["capsule.project": "other"]),
    ])
    await runtime.setVolumes([
        VolumeSummary(name: "demo_data", labels: ["capsule.project": "demo"]),
        VolumeSummary(name: "other_data", labels: ["capsule.project": "other"]),
    ])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      api: { image: alpine }
    """, directory: root))

    let preview = try await project.downPreview()

    #expect(preview == ComposeDownPreview(
        containers: ["demo-api-1"],
        networks: ["demo_default"],
        volumes: ["demo_data"]
    ))
}

@Test func downKeepsOrphansUnlessRequestedAndUsesStopGracePeriod() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([
        ContainerSummary(id: "demo-web-1", status: "running", imageReference: nil, addresses: [], labels: [
            "capsule.project": "demo", "capsule.service": "web", "capsule.index": "1",
        ]),
        ContainerSummary(id: "demo-old-1", status: "stopped", imageReference: nil, addresses: [], labels: [
            "capsule.project": "demo", "capsule.service": "old", "capsule.index": "1",
        ]),
    ])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      web:
        image: nginx
        stop_grace_period: 1500ms
    """, directory: root))

    for try await _ in try await project.down() {}
    let calls = await runtime.calls
    #expect(calls.contains(.stopContainer(id: "demo-web-1", timeoutSeconds: 2)))
    #expect(calls.contains(.deleteContainer(id: "demo-web-1", force: true)))
    #expect(!calls.contains(.deleteContainer(id: "demo-old-1", force: true)))
}

@Test func upMergesExistingSupervisorStateAndPersistsExactSourceFile() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setImages([ImageSummary(id: "alpine", reference: "alpine")])
    await runtime.setNetworks([NetworkSummary(name: "demo_default")])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.saveState(StoredProjectState(
        revision: "old",
        desiredRunning: false,
        serviceConfigHashes: ["app": "old"],
        services: ["app": StoredServiceState(
            containerID: "previous",
            desiredRunning: false,
            stoppedByUser: true,
            health: .unhealthy,
            restartAttempts: 4
        )]
    ), projectID: "demo")
    let input = source("""
    name: demo
    services:
      app: { image: alpine }
    """, directory: root)
    let project = try await ComposeEngine(runtime: runtime, store: store).open(input)
    let prepared = try await project.prepareUp()
    for try await _ in try await project.up(prepared) {}

    let state = try store.loadState(projectID: "demo")
    let service = try #require(state.services["app"])
    #expect(service.containerID == "demo-app-1")
    #expect(!service.stoppedByUser)
    #expect(service.health == .unhealthy)
    #expect(service.restartAttempts == 4)
    #expect(service.desiredRunning)
    #expect(try store.loadProject(id: "demo").sourcePath == input.filePath)
}

@Test func driftUsesStoredStoppedDesiredState() async throws {
    let runtime = FakeContainerRuntime()
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      app: { image: alpine }
    """, directory: root))
    let prepared = try await project.prepareUp()
    let spec = try #require(prepared.plan.steps.compactMap { step -> RunSpec? in
        guard case .ensureContainer("app", let spec) = step else { return nil }
        return spec
    }.first)
    await runtime.setContainers([ContainerSummary(
        id: "demo-app-1", status: "stopped", imageReference: "alpine", addresses: [], labels: spec.labels
    )])
    await runtime.setNetworks([NetworkSummary(name: "demo_default")])
    try store.saveState(StoredProjectState(
        revision: "stored",
        desiredRunning: false,
        serviceConfigHashes: ["app": spec.labels["capsule.config-hash"] ?? ""],
        services: ["app": StoredServiceState(desiredRunning: false)]
    ), projectID: "demo")

    #expect(try await project.status().drift?.isInSync == true)
}

@Test func downThenStatusTreatsRemovedStoppedServicesAsConverged() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setImages([ImageSummary(id: "alpine", reference: "alpine")])
    await runtime.setNetworks([NetworkSummary(name: "demo_default")])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      app: { image: alpine }
    """, directory: root))

    let prepared = try await project.prepareUp()
    for try await _ in try await project.up(prepared) {}
    for try await _ in try await project.down() {}

    let status = try await project.status()
    #expect(status.services.map(\.runtimeState) == [.unknown])
    #expect(status.drift?.isInSync == true)
}

@Test func upReplacesStaleProjectReopenMetadata() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setImages([ImageSummary(id: "alpine", reference: "alpine")])
    await runtime.setNetworks([NetworkSummary(name: "demo_default")])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.saveProject(ProjectRecord(
        id: "demo",
        name: "demo",
        sourcePath: "/old/compose.yaml",
        environmentFilePaths: ["/old/project.env"],
        projectNameOverride: "old-name",
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    let newFile = root.appendingPathComponent("moved-stack.yaml")
    let newEnv = root.appendingPathComponent("release.env")
    let input = ComposeSource(
        yaml: "services:\n  app: { image: alpine }\n",
        projectName: "demo",
        fallbackName: "ignored",
        workingDirectory: root.path,
        filePath: newFile.path,
        environmentFilePaths: [newEnv.path]
    )
    let project = try await ComposeEngine(runtime: runtime, store: store).open(input)

    let prepared = try await project.prepareUp()
    for try await _ in try await project.up(prepared) {}

    let record = try store.loadProject(id: "demo")
    #expect(record.sourcePath == newFile.path)
    #expect(record.environmentFilePaths == [newEnv.path])
    #expect(record.projectNameOverride == "demo")
    #expect(record.createdAt == Date(timeIntervalSince1970: 1))
}

@Test func projectLogsSpoolEveryDeliveredLine() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([ContainerSummary(id: "demo-app-1", status: "running", imageReference: "alpine", addresses: [], labels: [
        "capsule.project": "demo", "capsule.service": "app", "capsule.index": "1",
    ])])
    await runtime.setLogLines([LogLine(text: "one"), LogLine(text: "two")], forID: "demo-app-1")
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      app: { image: alpine }
    """, directory: root))

    var delivered: [String] = []
    for try await entry in try await project.logs() { delivered.append(entry.line.text) }
    #expect(delivered == ["one", "two"])
    let contents = try String(
        contentsOf: try store.logFile(projectID: "demo", service: "app"),
        encoding: .utf8
    )
    #expect(contents == "one\ntwo\n")
}

@Test func projectDependencyGraphPreservesConditionsAndStartLayers() async throws {
    let runtime = FakeContainerRuntime()
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      database:
        image: postgres
      cache:
        image: redis
      api:
        image: api
        depends_on:
          database:
            condition: service_healthy
          cache:
            condition: service_started
      web:
        image: web
        depends_on:
          api:
            condition: service_started
    """, directory: root))

    let graph = try await project.dependencyGraph()

    #expect(graph.services == ["api", "cache", "database", "web"])
    #expect(graph.startLayers == [["cache", "database"], ["api"], ["web"]])
    #expect(graph.edges == [
        .init(dependency: "api", dependent: "web", condition: .serviceStarted),
        .init(dependency: "cache", dependent: "api", condition: .serviceStarted),
        .init(dependency: "database", dependent: "api", condition: .serviceHealthy),
    ])
}

@Test func composeServiceOperationsPersistUserIntentForResidentSupervision() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setContainers([ContainerSummary(
        id: "demo-api-1",
        status: "running",
        imageReference: "api",
        addresses: [],
        labels: [
            "capsule.project": "demo",
            "capsule.service": "api",
            "capsule.index": "1",
        ]
    )])
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.saveState(StoredProjectState(
        revision: "revision",
        desiredRunning: true,
        serviceConfigHashes: ["api": "hash"],
        services: [
            "api": StoredServiceState(
                containerID: "demo-api-1",
                desiredRunning: true
            ),
        ]
    ), projectID: "demo")
    let project = try await ComposeEngine(runtime: runtime, store: store).open(source("""
    name: demo
    services:
      api: { image: api }
    """, directory: root))

    for try await _ in try await project.stop() {}
    var state = try store.loadState(projectID: "demo")
    #expect(state.services["api"]?.desiredRunning == false)
    #expect(state.services["api"]?.stoppedByUser == true)

    for try await _ in try await project.start() {}
    state = try store.loadState(projectID: "demo")
    #expect(state.services["api"]?.desiredRunning == true)
    #expect(state.services["api"]?.stoppedByUser == false)

    for try await _ in try await project.restart() {}
    state = try store.loadState(projectID: "demo")
    #expect(state.services["api"]?.desiredRunning == true)
    #expect(state.services["api"]?.stoppedByUser == false)
}
