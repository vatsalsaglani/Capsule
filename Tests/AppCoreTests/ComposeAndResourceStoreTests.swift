import AppCore
import ComposeRuntime
import ContainerClient
import ContainerClientTestSupport
import Foundation
import ProjectStore
import Testing

@MainActor
@Test func composeImportCreatesAProjectAndPreparesAReviewablePlan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("custom-stack.yaml")
    try "services:\n  web:\n    image: nginx:latest\n".write(to: file, atomically: true, encoding: .utf8)

    let fake = FakeContainerRuntime()
    let projects = ComposeProjectsStore(runtime: fake, store: ProjectStore(rootDirectory: root.appendingPathComponent("state")))
    let item = try await projects.importFile(file)
    #expect(item.name == root.lastPathComponent)
    guard case .loaded(let loaded) = projects.phase else { Issue.record("expected loaded projects"); return }
    #expect(loaded == [item])

    let reloadedProjects = ComposeProjectsStore(
        runtime: fake,
        store: ProjectStore(rootDirectory: root.appendingPathComponent("state"))
    )
    await reloadedProjects.refresh()
    #expect(reloadedProjects.phase == .loaded([item]))

    let detail = projects.makeDetailStore(for: item)
    await detail.load()
    #expect(detail.canOperate)
    #expect(detail.services.map(\.service) == ["web"])
    #expect(detail.resolvedConfiguration.contains("services:"))
    #expect(detail.configReport.contains("/etc/hosts"))
    await detail.prepareUp()
    #expect(detail.planLines.contains { $0.contains("nginx:latest") })
    #expect(detail.planLines.contains { $0.contains("ensure container") })
    await detail.confirmUp()
    #expect(detail.operationLines.contains { $0.hasPrefix("→ ") })
}

@MainActor
@Test func composeLogDisplayIsBoundedWhileEngineSpoolsTheFullStream() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("compose.yaml")
    try "name: demo\nservices:\n  app: { image: alpine }\n".write(to: file, atomically: true, encoding: .utf8)
    let fake = FakeContainerRuntime()
    await fake.setContainers([ContainerSummary(
        id: "demo-app-1", status: "running", imageReference: "alpine", addresses: [],
        labels: ["capsule.project": "demo", "capsule.service": "app", "capsule.index": "1"]
    )])
    await fake.setLogLines((0..<2_005).map { LogLine(text: "line-\($0)") }, forID: "demo-app-1")
    let projects = ComposeProjectsStore(runtime: fake, store: ProjectStore(rootDirectory: root.appendingPathComponent("state")))
    let item = try await projects.importFile(file)
    let detail = projects.makeDetailStore(for: item)
    await detail.load()
    let task = try #require(detail.startLogs(follow: false))
    await task.value

    #expect(detail.logs.count == 2_000)
    #expect(detail.logs.first?.text == "line-5")
    #expect(detail.logs.last?.text == "line-2004")
    #expect(detail.logError == nil)
    #expect(!detail.isFollowingLogs)
}

@MainActor
@Test func composeDownPreviewIsPreparedBeforeAnyMutationRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("compose.yaml")
    try "name: demo\nservices:\n  app: { image: alpine }\n"
        .write(to: file, atomically: true, encoding: .utf8)
    let fake = FakeContainerRuntime()
    await fake.setContainers([ContainerSummary(
        id: "demo-app-1",
        status: "running",
        imageReference: "alpine",
        addresses: [],
        labels: ["capsule.project": "demo", "capsule.service": "app"]
    )])
    await fake.setNetworks([NetworkSummary(name: "demo_default", labels: ["capsule.project": "demo"])])
    await fake.setVolumes([VolumeSummary(name: "demo_data", labels: ["capsule.project": "demo"])])
    let projects = ComposeProjectsStore(
        runtime: fake,
        store: ProjectStore(rootDirectory: root.appendingPathComponent("state"))
    )
    let item = try await projects.importFile(file)
    let detail = projects.makeDetailStore(for: item)
    await detail.load()

    #expect(await detail.prepareDownPreview())
    #expect(detail.downPreview == ComposeDownPreview(
        containers: ["demo-app-1"],
        networks: ["demo_default"],
        volumes: ["demo_data"]
    ))
    #expect(!(await fake.calls).contains { call in
        switch call {
        case .stopContainer, .deleteContainer, .deleteNetwork, .deleteVolume: true
        default: false
        }
    })
}

@MainActor
@Test func composeRefreshMergesStoredAndRuntimeOnlyProjectsWithoutDroppingMissingSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectStore = ProjectStore(rootDirectory: root)
    try projectStore.saveProject(ProjectRecord(
        id: "moved",
        name: "Moved Project",
        sourcePath: root.appendingPathComponent("no-longer-here.yaml").path,
        createdAt: .now
    ))
    let fake = FakeContainerRuntime()
    await fake.setVolumes([VolumeSummary(
        name: "runtime-only_data",
        labels: ["capsule.project": "runtime-only"]
    )])
    let projects = ComposeProjectsStore(runtime: fake, store: projectStore)

    await projects.refresh()

    guard case .loaded(let items) = projects.phase else {
        Issue.record("expected merged project list")
        return
    }
    #expect(items.map(\.id) == ["moved", "runtime-only"])
    #expect(items.allSatisfy { $0.fileURL == nil })
    #expect(items.first { $0.id == "moved" }?.sourceUnavailableDescription?.contains("no-longer-here.yaml") == true)
    #expect(items.first { $0.id == "runtime-only" }?.sourceUnavailableDescription?.contains("re-import") == true)

    let unavailableDetail = projects.makeDetailStore(for: try #require(items.first { $0.id == "runtime-only" }))
    await unavailableDetail.load()
    #expect(!unavailableDetail.canOperate)
    #expect(await unavailableDetail.prepareUp() == false)
    #expect(unavailableDetail.planLines.isEmpty)
    guard case .failed(let message) = unavailableDetail.phase else {
        Issue.record("expected unavailable-source detail failure")
        return
    }
    #expect(message.contains("re-import"))
}

@MainActor
@Test func composeRefreshKeepsPersistedProjectsWhenRuntimeDiscoveryPartiallyFails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("compose.yaml")
    try "name: saved\nservices:\n  app: { image: alpine }\n"
        .write(to: file, atomically: true, encoding: .utf8)
    let projectStore = ProjectStore(rootDirectory: root.appendingPathComponent("state"))
    try projectStore.saveProject(ProjectRecord(
        id: "saved",
        name: "saved",
        sourcePath: file.path,
        createdAt: .now
    ))
    let fake = FakeContainerRuntime()
    await fake.setError(RuntimeError.notImplemented(operation: "container list"), for: .listContainers)
    await fake.setError(RuntimeError.notImplemented(operation: "network list"), for: .listNetworks)
    await fake.setVolumes([VolumeSummary(
        name: "discovered_data",
        labels: ["capsule.project": "discovered"]
    )])
    let projects = ComposeProjectsStore(runtime: fake, store: projectStore)

    await projects.refresh()

    guard case .loaded(let items) = projects.phase else {
        Issue.record("persisted projects must survive runtime discovery failures")
        return
    }
    #expect(items.map(\.id) == ["discovered", "saved"])
    #expect(items.first { $0.id == "saved" }?.sourceAvailable == true)
    #expect(projects.discoveryWarning?.contains("containers:") == true)
    #expect(projects.discoveryWarning?.contains("networks:") == true)
    #expect(projects.discoveryWarning?.contains("Saved projects remain available") == true)
}

@MainActor
@Test func composeDetailReplaysSavedProjectOverrideAndExplicitEnvironmentFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("production-stack.yaml")
    let environmentFile = root.appendingPathComponent("production.env")
    try "services:\n  app: { image: '${CAPSULE_REOPEN_IMAGE}' }\n"
        .write(to: file, atomically: true, encoding: .utf8)
    try "CAPSULE_REOPEN_IMAGE=alpine:3.20\n"
        .write(to: environmentFile, atomically: true, encoding: .utf8)
    let projectStore = ProjectStore(rootDirectory: root.appendingPathComponent("state"))
    try projectStore.saveProject(ProjectRecord(
        id: "production",
        name: "production",
        sourcePath: file.path,
        environmentFilePaths: [environmentFile.path],
        projectNameOverride: "production",
        createdAt: .now
    ))
    let fake = FakeContainerRuntime()
    let projects = ComposeProjectsStore(runtime: fake, store: projectStore)
    await projects.refresh()
    guard case .loaded(let items) = projects.phase, let item = items.first else {
        Issue.record("expected saved project")
        return
    }

    let detail = projects.makeDetailStore(for: item)
    await detail.load()

    #expect(detail.phase == .loaded)
    #expect(detail.resolvedConfiguration.contains("alpine:3.20"))
    #expect(detail.services.map(\.service) == ["app"])
}

@MainActor
@Test func volumeStoreLoadsReverseReferencesAndDrivesMutations() async throws {
    let fake = FakeContainerRuntime()
    await fake.setVolumes([VolumeSummary(name: "data", sizeInBytes: 4096)])
    let store = VolumesStore(runtime: fake)
    await store.refresh()
    guard case .loaded(let volumes) = store.phase else { Issue.record("expected volumes"); return }
    #expect(volumes.map(\.summary.name) == ["data"])

    await store.create(name: "cache", capacityBytes: 1024)
    await store.prune()
    let calls = await fake.calls
    #expect(calls.contains(.createVolume(VolumeCreateSpec(name: "cache", capacityBytes: 1024))))
    #expect(calls.contains(.pruneVolumes))
}

@MainActor
@Test func networkStoreProtectsBuiltInAndCreatesRichNetworkSpecs() async throws {
    let fake = FakeContainerRuntime()
    let builtin = NetworkSummary(name: "default", labels: ["com.apple.container.resource.role": "builtin"])
    await fake.setNetworks([builtin])
    let store = NetworksStore(runtime: fake)
    await store.refresh()
    guard case .loaded(let networks) = store.phase, let record = networks.first else {
        Issue.record("expected network"); return
    }
    await store.delete(record)
    #expect(store.actionError == "The built-in network cannot be deleted.")

    await store.create(name: "private", isInternal: true, ipv4Subnet: "10.10.0.0/24", ipv6Subnet: nil)
    #expect(store.actionError == nil)
    let calls = await fake.calls
    #expect(calls.contains(.createNetwork(NetworkCreateSpec(
        name: "private", connectivity: .hostOnly, ipv4Subnet: "10.10.0.0/24"
    ))))
    #expect(!calls.contains(.deleteNetwork(name: "default")))
}
