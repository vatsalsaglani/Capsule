import AppCore
import ContainerClient
import ContainerClientTestSupport
import Foundation
import Testing

/// Same polling-oracle discipline as `ContainerListStoreTests.waitUntil` —
/// duplicated here (file-private) rather than shared, since that helper is
/// itself file-scoped `private`.
@MainActor
private func waitUntil(
    timeout: Duration = .milliseconds(500),
    pollEvery: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async -> Bool {
    if condition() { return true }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollEvery)
        if condition() { return true }
    }
    return condition()
}

private struct ProbeError: Error, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A `ContainerRuntime` wrapping a `FakeContainerRuntime` that overrides only
/// `pullImage(reference:platform:)` with a controllable, artificially-paced
/// stream — `FakeContainerRuntime.pullImage` yields every preset event and
/// finishes essentially synchronously, which can't exercise "the store
/// actually progresses through intermediate `.pulling(lines:)` states before
/// the terminal one" the way this file's progression test needs (same
/// posture as `ContainerDetailStoreTests.SlowStatsRuntime`'s doc comment).
/// Forwards every other method to the wrapped fake so it's otherwise a
/// drop-in `ContainerRuntime`.
private actor SlowPullRuntime: ContainerRuntime {
    private let base: FakeContainerRuntime

    init(base: FakeContainerRuntime) { self.base = base }

    func cliVersion() async throws -> SemanticVersion { try await base.cliVersion() }
    func systemStatus() async throws -> SystemStatus { try await base.systemStatus() }
    func systemDiskUsage() async throws -> SystemDiskUsage { try await base.systemDiskUsage() }
    func systemStart() async throws { try await base.systemStart() }
    func systemStop() async throws { try await base.systemStop() }
    func listContainers(all: Bool) async throws -> [ContainerSummary] { try await base.listContainers(all: all) }
    func inspectContainer(id: String) async throws -> ContainerDetail { try await base.inspectContainer(id: id) }
    func createContainer(_ spec: RunSpec) async throws -> String { try await base.createContainer(spec) }
    func startContainer(id: String) async throws { try await base.startContainer(id: id) }
    func stopContainer(id: String, timeoutSeconds: Int?) async throws {
        try await base.stopContainer(id: id, timeoutSeconds: timeoutSeconds)
    }
    func killContainer(id: String, signal: String) async throws { try await base.killContainer(id: id, signal: signal) }
    func deleteContainer(id: String, force: Bool) async throws { try await base.deleteContainer(id: id, force: force) }
    func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        try await base.logs(id: id, follow: follow, tail: tail)
    }
    func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        try await base.exec(id: id, argv: argv, timeout: timeout)
    }
    func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> { try await base.stats(ids: ids) }
    func listImages() async throws -> [ImageSummary] { try await base.listImages() }

    func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PullProgress.self)
        Task {
            continuation.yield(PullProgress(message: "Resolving \(reference)"))
            try? await Task.sleep(for: .milliseconds(30))
            continuation.yield(PullProgress(message: "Downloading"))
            try? await Task.sleep(for: .milliseconds(30))
            continuation.finish()
        }
        return stream
    }

    func deleteImage(reference: String) async throws { try await base.deleteImage(reference: reference) }
    func tagImage(source: String, target: String) async throws { try await base.tagImage(source: source, target: target) }
    func listVolumes() async throws -> [VolumeSummary] { try await base.listVolumes() }
    func createVolume(name: String, labels: [String: String]) async throws {
        try await base.createVolume(name: name, labels: labels)
    }
    func deleteVolume(name: String) async throws { try await base.deleteVolume(name: name) }
    func listNetworks() async throws -> [NetworkSummary] { try await base.listNetworks() }
    func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        try await base.createNetwork(name: name, labels: labels, isInternal: isInternal)
    }
    func deleteNetwork(name: String) async throws { try await base.deleteNetwork(name: name) }
}

// MARK: - 1. refresh()

@MainActor
@Test func refreshLoadsCannedImages() async throws {
    let fake = FakeContainerRuntime()
    let images = [ImageSummary(id: "img-1", reference: "nginx:latest"), ImageSummary(id: "img-2", reference: "redis:7")]
    await fake.setImages(images)
    let store = ImagesStore(runtime: fake)

    await store.refresh()

    #expect(store.phase == .loaded(images))
}

@MainActor
@Test func imagesRefreshSurfacesAFailureAsThePhase() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "no such runtime"), for: .listImages)
    let store = ImagesStore(runtime: fake)

    await store.refresh()

    #expect(store.phase == .failed(message: "no such runtime"))
}

// MARK: - 2. pull() progression

@MainActor
@Test func pullProgressesThroughLinesToDoneAndTriggersARefresh() async throws {
    let fake = FakeContainerRuntime()
    await fake.setImages([ImageSummary(id: "img-1", reference: "nginx:latest")])
    let slow = SlowPullRuntime(base: fake)
    let store = ImagesStore(runtime: slow)

    store.pull(reference: "nginx:latest", platform: nil)

    #expect(await waitUntil {
        if case .pulling(let lines) = store.pullPhase { return !lines.isEmpty }
        return false
    })
    #expect(await waitUntil { store.pullPhase == .done })
    // The post-done refresh() should have loaded the canned image list.
    #expect(await waitUntil { store.phase == .loaded([ImageSummary(id: "img-1", reference: "nginx:latest")]) })

    let calls = await fake.calls
    #expect(calls.contains(.listImages))
}

@MainActor
@Test func pullSurfacesAnInjectedFailureAsPullPhaseFailed() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "network unreachable"), for: .pullImage)
    let store = ImagesStore(runtime: fake)

    store.pull(reference: "nginx:latest", platform: nil)

    #expect(await waitUntil { store.pullPhase == .failed(message: "network unreachable") })
}

@MainActor
@Test func dismissPullResetsToIdle() async throws {
    let fake = FakeContainerRuntime()
    await fake.setPullEvents([PullProgress(message: "Resolving")], forReference: "nginx:latest")
    let store = ImagesStore(runtime: fake)

    store.pull(reference: "nginx:latest", platform: nil)
    #expect(await waitUntil { store.pullPhase == .done })

    store.dismissPull()
    #expect(store.pullPhase == .idle)
}

// MARK: - 3. Mutations trigger refresh (fake.calls ordering)

@MainActor
@Test func tagSucceedsThenTriggersARefresh() async throws {
    let fake = FakeContainerRuntime()
    await fake.setImages([ImageSummary(id: "img-1", reference: "nginx:v2")])
    let store = ImagesStore(runtime: fake)

    await store.tag(source: "nginx:latest", target: "nginx:v2")

    #expect(store.lastActionError == nil)
    #expect(store.phase == .loaded([ImageSummary(id: "img-1", reference: "nginx:v2")]))
    let calls = await fake.calls
    #expect(calls == [.tagImage(source: "nginx:latest", target: "nginx:v2"), .listImages])
}

@MainActor
@Test func tagFailureSurfacesAsLastActionErrorAndSkipsRefresh() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "no such image"), for: .tagImage)
    let store = ImagesStore(runtime: fake)

    await store.tag(source: "missing:latest", target: "missing:v2")

    #expect(store.lastActionError == ImagesStore.ActionError(reference: "missing:latest", message: "no such image"))
    let calls = await fake.calls
    #expect(calls == [.tagImage(source: "missing:latest", target: "missing:v2")]) // no follow-up listImages
}

@MainActor
@Test func deleteSucceedsThenTriggersARefresh() async throws {
    let fake = FakeContainerRuntime()
    await fake.setImages([])
    let store = ImagesStore(runtime: fake)

    await store.delete(reference: "nginx:latest")

    #expect(store.lastActionError == nil)
    #expect(store.phase == .loaded([]))
    let calls = await fake.calls
    #expect(calls == [.deleteImage(reference: "nginx:latest"), .listImages])
}

@MainActor
@Test func imagesDismissActionErrorClearsIt() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "boom"), for: .deleteImage)
    let store = ImagesStore(runtime: fake)

    await store.delete(reference: "nginx:latest")
    #expect(store.lastActionError != nil)

    store.dismissActionError()
    #expect(store.lastActionError == nil)
}

// MARK: - 4. isInUse (pure function)

@Test func isInUseTrueWhenAContainerReferencesTheImage() {
    let image = ImageSummary(id: "img-1", reference: "nginx:latest")
    let containers = [ContainerSummary(id: "web-1", status: "running", imageReference: "nginx:latest", addresses: [])]

    #expect(ImagesStore.isInUse(image, byContainers: containers))
}

@Test func isInUseFalseWhenNoContainerReferencesTheImage() {
    let image = ImageSummary(id: "img-1", reference: "nginx:latest")
    let containers = [ContainerSummary(id: "web-1", status: "running", imageReference: "redis:7", addresses: [])]

    #expect(ImagesStore.isInUse(image, byContainers: containers) == false)
}

@Test func isInUseFalseForAnEmptyContainerList() {
    let image = ImageSummary(id: "img-1", reference: "nginx:latest")

    #expect(ImagesStore.isInUse(image, byContainers: []) == false)
}
