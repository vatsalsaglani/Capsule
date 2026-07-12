import AppCore
import ContainerClient
import ContainerClientTestSupport
import Foundation
import Testing

private struct ProbeError: Error, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func makeDiskUsage() -> SystemDiskUsage {
    SystemDiskUsage(
        containers: ResourceUsage(total: 2, active: 1, sizeInBytes: 1_000, reclaimableBytes: 200),
        images: ResourceUsage(total: 3, active: 2, sizeInBytes: 5_000, reclaimableBytes: 1_000),
        volumes: ResourceUsage(total: 1, active: 1, sizeInBytes: 500, reclaimableBytes: 0)
    )
}

// MARK: - 1. refresh()

@MainActor
@Test func refreshLoadsCannedStatusAndDiskUsage() async throws {
    let fake = FakeContainerRuntime()
    let status = SystemStatus(status: "running", apiServerVersion: "1.1.0")
    let diskUsage = makeDiskUsage()
    await fake.setSystemStatus(status)
    await fake.setDiskUsage(diskUsage)
    let store = SystemStore(runtime: fake)

    await store.refresh()

    #expect(store.phase == .loaded(status: status, diskUsage: diskUsage))
}

@MainActor
@Test func systemRefreshSurfacesAFailureAsThePhase() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "runtime unreachable"), for: .systemStatus)
    let store = SystemStore(runtime: fake)

    await store.refresh()

    #expect(store.phase == .failed(message: "runtime unreachable"))
}

// MARK: - 2. startRuntime()/stopRuntime()

@MainActor
@Test func startRuntimeRecordsTheCallAndRefreshes() async throws {
    let fake = FakeContainerRuntime()
    await fake.setSystemStatus(SystemStatus(status: "running"))
    let store = SystemStore(runtime: fake)

    await store.startRuntime()

    #expect(store.lastActionError == nil)
    if case .loaded(let status, _) = store.phase {
        #expect(status.status == "running")
    } else {
        Issue.record("expected .loaded, got \(store.phase)")
    }
    // `refresh()` fires `systemStatus`/`systemDiskUsage` concurrently via
    // `async let` (both pass-through on `RuntimeGateway` — no ordering
    // guarantee between the two), so only `.systemStart` (strictly
    // sequential, before `refresh()` is even called) has a pinned position.
    let calls = await fake.calls
    #expect(calls.first == .systemStart)
    #expect(calls.count == 3)
    #expect(calls.contains(.systemStatus))
    #expect(calls.contains(.systemDiskUsage))
}

@MainActor
@Test func stopRuntimeRecordsTheCallAndRefreshes() async throws {
    let fake = FakeContainerRuntime()
    await fake.setSystemStatus(SystemStatus(status: "stopped"))
    let store = SystemStore(runtime: fake)

    await store.stopRuntime()

    #expect(store.lastActionError == nil)
    let calls = await fake.calls
    #expect(calls.first == .systemStop)
    #expect(calls.count == 3)
    #expect(calls.contains(.systemStatus))
    #expect(calls.contains(.systemDiskUsage))
}

@MainActor
@Test func startRuntimeFailureSurfacesAsLastActionErrorAndSkipsRefresh() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "already running"), for: .systemStart)
    let store = SystemStore(runtime: fake)

    await store.startRuntime()

    #expect(store.lastActionError == "already running")
    let calls = await fake.calls
    #expect(calls == [.systemStart]) // no follow-up refresh
}

@MainActor
@Test func stopRuntimeFailureSurfacesAsLastActionError() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "already stopped"), for: .systemStop)
    let store = SystemStore(runtime: fake)

    await store.stopRuntime()

    #expect(store.lastActionError == "already stopped")
}

@MainActor
@Test func systemDismissActionErrorClearsIt() async throws {
    let fake = FakeContainerRuntime()
    await fake.setError(ProbeError(message: "boom"), for: .systemStart)
    let store = SystemStore(runtime: fake)

    await store.startRuntime()
    #expect(store.lastActionError != nil)

    store.dismissActionError()
    #expect(store.lastActionError == nil)
}
