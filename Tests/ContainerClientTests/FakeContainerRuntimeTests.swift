import Foundation
import Testing
import ContainerClient
import ContainerClientTestSupport

@Test func fakeContainerRuntimeRoundTripsEveryMethodAndRecordsCalls() async throws {
    let fake = FakeContainerRuntime()
    let runtime: any ContainerRuntime = fake

    await fake.setCLIVersion(SemanticVersion(major: 1, minor: 2, patch: 3))
    await fake.setSystemStatus(SystemStatus(status: "running"))
    let kernelReadiness = DefaultKernelReadiness.configured(for: .arm64)
    await fake.setDefaultKernelReadiness(kernelReadiness)
    let diskUsage = SystemDiskUsage(
        containers: ResourceUsage(total: 1, active: 1, sizeInBytes: 10, reclaimableBytes: 0),
        images: ResourceUsage(total: 2, active: 1, sizeInBytes: 20, reclaimableBytes: 5),
        volumes: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0)
    )
    await fake.setDiskUsage(diskUsage)

    let summary = ContainerSummary(id: "web-1", status: "running", imageReference: "nginx:latest", addresses: ["10.0.0.2"])
    await fake.setContainers([summary])

    let detail = ContainerDetail(id: "web-1", status: "running")
    await fake.setDetail(detail, forID: "web-1")

    let lines = [LogLine(text: "starting\n"), LogLine(text: "ready\n")]
    await fake.setLogLines(lines, forID: "web-1")

    let ticks: [[StatsSample]] = [[
        StatsSample(
            id: "web-1", cpuUsageMicroseconds: 100, memoryUsageBytes: 200, memoryLimitBytes: 300,
            blockReadBytes: 1, blockWriteBytes: 2, networkReceivedBytes: 3, networkSentBytes: 4, processCount: 1
        ),
    ]]
    await fake.setStatsTicks(ticks)

    let execResult = ExecResult(exitCode: 0, stdout: Data("ok".utf8), stderr: Data())
    await fake.setExecResult(execResult, forID: "web-1")

    let image = ImageSummary(id: "sha256:abc", reference: "nginx:latest")
    await fake.setImages([image])

    let pullEvents = [PullProgress(message: "downloading"), PullProgress(message: "done")]
    await fake.setPullEvents(pullEvents, forReference: "nginx:latest")

    let volume = VolumeSummary(name: "demo-vol")
    await fake.setVolumes([volume])

    let network = NetworkSummary(name: "demo_default")
    await fake.setNetworks([network])

    // Exercise every protocol method through the `any ContainerRuntime`
    // existential, not the concrete actor type.
    #expect(try await runtime.cliVersion() == SemanticVersion(major: 1, minor: 2, patch: 3))
    #expect(try await runtime.systemStatus() == SystemStatus(status: "running"))
    #expect(try await runtime.defaultKernelReadiness() == kernelReadiness)
    #expect(try await runtime.systemDiskUsage() == diskUsage)
    #expect(try await runtime.listContainers(all: true) == [summary])
    #expect(try await runtime.inspectContainer(id: "web-1") == detail)

    let namedSpec = RunSpec(image: "nginx:latest").with { $0.name = "web-2" }
    #expect(try await runtime.createContainer(namedSpec) == "web-2")

    let firstUnnamedSpec = RunSpec(image: "nginx:latest")
    let firstAutoID = try await runtime.createContainer(firstUnnamedSpec)
    let secondUnnamedSpec = RunSpec(image: "nginx:latest").with { $0.command = ["echo", "hi"] }
    let secondAutoID = try await runtime.createContainer(secondUnnamedSpec)
    #expect(firstAutoID == "fake-2")
    #expect(secondAutoID == "fake-3")

    try await runtime.startContainer(id: "web-1")
    try await runtime.stopContainer(id: "web-1", timeoutSeconds: 5)
    try await runtime.killContainer(id: "web-1", signal: "SIGTERM")

    var collectedLines: [LogLine] = []
    for try await line in try await runtime.logs(id: "web-1", follow: false, tail: nil) {
        collectedLines.append(line)
    }
    #expect(collectedLines == lines)

    #expect(try await runtime.exec(id: "web-1", argv: ["echo", "hi"], timeout: .seconds(5)) == execResult)

    var collectedTicks: [[StatsSample]] = []
    for try await tick in try await runtime.stats(ids: ["web-1"]) {
        collectedTicks.append(tick)
    }
    #expect(collectedTicks == ticks)

    #expect(try await runtime.listImages() == [image])

    var collectedPullEvents: [PullProgress] = []
    for try await event in try await runtime.pullImage(reference: "nginx:latest", platform: nil) {
        collectedPullEvents.append(event)
    }
    #expect(collectedPullEvents == pullEvents)

    try await runtime.deleteImage(reference: "nginx:latest")
    try await runtime.tagImage(source: "nginx:latest", target: "nginx:pinned")

    #expect(try await runtime.listVolumes() == [volume])
    try await runtime.createVolume(name: "demo-vol-2", labels: ["capsule.project": "demo"])
    try await runtime.deleteVolume(name: "demo-vol")

    #expect(try await runtime.listNetworks() == [network])
    try await runtime.createNetwork(name: "demo_net2", labels: [:], isInternal: true)
    try await runtime.deleteNetwork(name: "demo_default")

    try await runtime.deleteContainer(id: "web-1", force: true)

    let expectedCalls: [FakeContainerRuntime.Call] = [
        .cliVersion,
        .systemStatus,
        .defaultKernelReadiness,
        .systemDiskUsage,
        .listContainers(all: true),
        .inspectContainer(id: "web-1"),
        .createContainer(namedSpec),
        .createContainer(firstUnnamedSpec),
        .createContainer(secondUnnamedSpec),
        .startContainer(id: "web-1"),
        .stopContainer(id: "web-1", timeoutSeconds: 5),
        .killContainer(id: "web-1", signal: "SIGTERM"),
        .logs(id: "web-1", follow: false, tail: nil),
        .exec(id: "web-1", argv: ["echo", "hi"], timeout: .seconds(5)),
        .stats(ids: ["web-1"]),
        .listImages,
        .pullImage(reference: "nginx:latest", platform: nil),
        .deleteImage(reference: "nginx:latest"),
        .tagImage(source: "nginx:latest", target: "nginx:pinned"),
        .listVolumes,
        .createVolume(VolumeCreateSpec(name: "demo-vol-2", labels: ["capsule.project": "demo"])),
        .deleteVolume(name: "demo-vol"),
        .listNetworks,
        .createNetwork(NetworkCreateSpec(name: "demo_net2", connectivity: .hostOnly)),
        .deleteNetwork(name: "demo_default"),
        .deleteContainer(id: "web-1", force: true),
    ]
    let actualCalls = await fake.calls
    #expect(actualCalls == expectedCalls)
}

@Test func fakeContainerRuntimeInjectsAndClearsErrors() async throws {
    struct ProbeError: Error, Sendable, Equatable {}

    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(), for: .startContainer)

    await #expect(throws: ProbeError.self) {
        try await fake.startContainer(id: "web-1")
    }
    // The call is still recorded even though it threw.
    let callsAfterError = await fake.calls
    #expect(callsAfterError == [.startContainer(id: "web-1")])

    await fake.clearError(for: .startContainer)
    try await fake.startContainer(id: "web-1")

    let callsAfterClear = await fake.calls
    #expect(callsAfterClear == [.startContainer(id: "web-1"), .startContainer(id: "web-1")])
}

@Test func fakeContainerRuntimeResetRestoresDefaults() async throws {
    let fake = FakeContainerRuntime()
    await fake.setContainers([ContainerSummary(id: "x", status: "running", imageReference: nil, addresses: [])])
    _ = try await fake.listContainers(all: false)
    #expect(await fake.calls.count == 1)

    await fake.reset()
    #expect(await fake.calls.isEmpty)
    #expect(try await fake.listContainers(all: false).isEmpty)
    #expect(try await fake.cliVersion() == SemanticVersion(major: 1, minor: 1, patch: 0))
    #expect(try await fake.systemStatus().status == "running")
    #expect(try await fake.defaultKernelReadiness() == .configured())
}

@Test func fakeContainerRuntimeSupportsBuildAndTypedPruneOperations() async throws {
    let fake = FakeContainerRuntime()
    let buildSpec = ImageBuildSpec(
        contextDirectory: URL(fileURLWithPath: "/tmp/demo"),
        tag: "demo/web:dev"
    )
    let buildEvents = [
        BuildProgress(message: "#1 START", receivedAt: Date(timeIntervalSince1970: 1)),
        BuildProgress(message: "#1 DONE", receivedAt: Date(timeIntervalSince1970: 2)),
    ]
    await fake.setBuildEvents(buildEvents, forTag: buildSpec.tag)
    await fake.setVolumePruneReport(PruneReport(removedNames: ["old-volume"]))
    await fake.setNetworkPruneReport(PruneReport(removedNames: ["old-network"]))

    var received: [BuildProgress] = []
    for try await event in try await fake.buildImage(buildSpec) {
        received.append(event)
    }
    let volumeReport = try await fake.pruneVolumes()
    let networkReport = try await fake.pruneNetworks()

    #expect(received == buildEvents)
    #expect(volumeReport.removedNames == ["old-volume"])
    #expect(networkReport.removedNames == ["old-network"])
    #expect(await fake.calls == [
        .buildImage(buildSpec),
        .pruneVolumes,
        .pruneNetworks,
    ])
}

extension RunSpec {
    fileprivate func with(_ mutate: (inout RunSpec) -> Void) -> RunSpec {
        var copy = self
        mutate(&copy)
        return copy
    }
}
