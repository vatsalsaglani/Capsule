import AppCore
import ComposeSpec
import ContainerClient
import ContainerClientTestSupport
import EventBus
import Foundation
import ProjectStore
import Testing

/// Polls `condition` until it's true or `timeout` elapses, returning whether
/// it succeeded (swift-concurrency-pro `testing.md`: avoid `Task.sleep`-
/// then-assert-once as the oracle). Every test here wires the *real*
/// `RuntimePoller` + real `EventBus` + `FakeContainerRuntime` + real store —
/// this is the GUI-smoke substitute called for in the P1B brief, so state
/// changes genuinely arrive asynchronously off a poll tick and there is no
/// single async call to just `await` directly; a bounded poll loop is the
/// correct oracle here, not a fixed sleep guessed to be "long enough."
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

@MainActor
private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    pollEvery: Duration = .milliseconds(5),
    _ condition: @escaping () async -> Bool
) async -> Bool {
    if await condition() { return true }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollEvery)
        if await condition() { return true }
    }
    return await condition()
}

private struct ProbeError: Error, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func makeWebContainer(id: String, status: String) -> ContainerSummary {
    ContainerSummary(id: id, status: status, imageReference: "nginx", addresses: [])
}

// MARK: - 1. Live updates

@MainActor
@Test func storeReflectsLiveContainerUpdatesFromThePoller() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(
        runtime: fake, events: bus,
        interval: .milliseconds(15), idleInterval: .milliseconds(80), unavailableInterval: .milliseconds(15)
    )
    let store = ContainerListStore(runtime: fake, events: bus)

    let web1 = makeWebContainer(id: "web-1", status: "running")
    await fake.setContainers([web1])
    await store.start()
    await poller.start()

    #expect(await waitUntil { store.phase == .loaded([web1]) })

    let web2 = makeWebContainer(id: "web-2", status: "running")
    await fake.setContainers([web1, web2])
    #expect(await waitUntil { store.phase == .loaded([web1, web2]) })

    let web1Stopped = makeWebContainer(id: "web-1", status: "stopped")
    await fake.setContainers([web1Stopped, web2])
    #expect(await waitUntil { store.phase == .loaded([web1Stopped, web2]) })

    await fake.setContainers([web2])
    #expect(await waitUntil { store.phase == .loaded([web2]) })

    await poller.stop()
    store.stop()
}

// MARK: - 2 & 3. Graceful unavailable + recovery

@MainActor
@Test func storeGoesUnavailableOnListFailureThenRecoversOnClear() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(
        runtime: fake, events: bus,
        interval: .milliseconds(15), idleInterval: .milliseconds(80), unavailableInterval: .milliseconds(15)
    )
    let store = ContainerListStore(runtime: fake, events: bus)

    let web1 = makeWebContainer(id: "web-1", status: "running")
    await fake.setContainers([web1])
    await store.start()
    await poller.start()
    #expect(await waitUntil { store.phase == .loaded([web1]) })

    await fake.setError(ProbeError(message: "synthetic apiserver outage"), for: .listContainers)

    #expect(await waitUntil {
        store.phase == .unavailable(message: "synthetic apiserver outage", lastKnown: [web1])
    })

    // Several more failed poll ticks must not crash and must not churn the
    // phase away from the stable outage state.
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.phase == .unavailable(message: "synthetic apiserver outage", lastKnown: [web1]))

    // Recovery: clearing the error must return to `.loaded` with the
    // post-outage snapshot contents (a different container set proves this
    // is a fresh snapshot, not just the stale `lastKnown` reused).
    let web2 = makeWebContainer(id: "web-2", status: "running")
    await fake.setContainers([web2])
    await fake.clearError(for: .listContainers)

    #expect(await waitUntil { store.phase == .loaded([web2]) })

    await poller.stop()
    store.stop()
}

// MARK: - 4. Actions

@MainActor
@Test func startContainerRecordsTheCallAndClearsNoError() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerListStore(runtime: fake, events: bus)

    await store.startContainer(id: "web-1")

    #expect(await fake.calls == [.startContainer(id: "web-1")])
    #expect(store.lastActionError == nil)
}

@MainActor
@Test func startContainerFailureSetsLastActionErrorWithTheRealMessage() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerListStore(runtime: fake, events: bus)

    await fake.setError(ProbeError(message: "boom"), for: .startContainer)
    await store.startContainer(id: "web-1")

    #expect(store.lastActionError == ContainerListStore.ActionError(id: "web-1", message: "boom"))

    store.dismissActionError()
    #expect(store.lastActionError == nil)
}

@MainActor
@Test func restartContainerRecordsStopThenStartInOrder() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerListStore(runtime: fake, events: bus)

    await store.restartContainer(id: "web-1")

    #expect(await fake.calls == [
        .stopContainer(id: "web-1", timeoutSeconds: nil),
        .startContainer(id: "web-1"),
    ])
}

@MainActor
@Test func restartContainerStopsAtTheFailingStepAndRecordsItsError() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerListStore(runtime: fake, events: bus)

    await fake.setError(ProbeError(message: "stop failed"), for: .stopContainer)
    await store.restartContainer(id: "web-1")

    // The start must never be attempted once the stop failed.
    #expect(await fake.calls == [.stopContainer(id: "web-1", timeoutSeconds: nil)])
    #expect(store.lastActionError == ContainerListStore.ActionError(id: "web-1", message: "stop failed"))
}

@MainActor
@Test func stopAllRunningStopsExactlyTheRunningIDs() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    let store = ContainerListStore(runtime: fake, events: bus)

    let running1 = makeWebContainer(id: "a", status: "running")
    let stopped = makeWebContainer(id: "b", status: "stopped")
    let running2 = makeWebContainer(id: "c", status: "running")
    await fake.setContainers([running1, stopped, running2])

    await store.start()
    await poller.start()
    #expect(await waitUntil { store.phase == .loaded([running1, stopped, running2]) })

    await store.stopAllRunning()

    let stopCalls = await fake.calls.filter {
        if case .stopContainer = $0 { return true }
        return false
    }
    #expect(stopCalls == [
        .stopContainer(id: "a", timeoutSeconds: nil),
        .stopContainer(id: "c", timeoutSeconds: nil),
    ])

    await poller.stop()
    store.stop()
}

// MARK: - 4b. N2 — stopAllRunning tolerates "already stopped"

@MainActor
@Test func stopAllRunningToleratesAnAlreadyStoppedErrorAndStillStopsTheRest() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    let store = ContainerListStore(runtime: fake, events: bus)

    let running1 = makeWebContainer(id: "a", status: "running")
    let running2 = makeWebContainer(id: "b", status: "running")
    await fake.setContainers([running1, running2])
    await store.start()
    await poller.start()
    #expect(await waitUntil { store.phase == .loaded([running1, running2]) })

    await fake.setError(ProbeError(message: "container is already stopped"), for: .stopContainer)
    await store.stopAllRunning()

    // Both ids were still attempted (the benign race doesn't short-circuit
    // the loop) and no spurious `lastActionError` was recorded for either.
    let stopCalls = await fake.calls.filter {
        if case .stopContainer = $0 { return true }
        return false
    }
    #expect(stopCalls == [
        .stopContainer(id: "a", timeoutSeconds: nil),
        .stopContainer(id: "b", timeoutSeconds: nil),
    ])
    #expect(store.lastActionError == nil)

    await poller.stop()
    store.stop()
}

@MainActor
@Test func stopAllRunningStillSurfacesARealFailure() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    let store = ContainerListStore(runtime: fake, events: bus)

    let running = makeWebContainer(id: "a", status: "running")
    await fake.setContainers([running])
    await store.start()
    await poller.start()
    #expect(await waitUntil { store.phase == .loaded([running]) })

    await fake.setError(ProbeError(message: "internalError: some other real failure"), for: .stopContainer)
    await store.stopAllRunning()

    #expect(store.lastActionError == ContainerListStore.ActionError(id: "a", message: "internalError: some other real failure"))

    await poller.stop()
    store.stop()
}

// MARK: - 5. runtimeMissing

@MainActor
@Test func sessionPutsContainerStoreIntoRuntimeMissingWhenConstructionFails() async throws {
    let session = RuntimeSession(makeRuntime: { throw ProbeError(message: "container CLI not found") })

    guard case .runtimeMissing(let message) = session.containers.phase else {
        Issue.record("expected .runtimeMissing, got \(session.containers.phase)")
        return
    }
    #expect(message == "container CLI not found")

    // start()/stop() must be safe no-ops on this degraded path — no poller,
    // no bus subscription to spin up.
    await session.start()
    await session.stop()
    #expect(session.containers.phase == .runtimeMissing(message: "container CLI not found"))
}

// MARK: - 5b. N1 — RuntimeSession.start() ordering (containers before poller)

@MainActor
@Test func sessionStartsTheContainersSubscriptionBeforeThePollerSoTheFirstSnapshotIsNeverDropped() async throws {
    let fake = FakeContainerRuntime()
    let web1 = makeWebContainer(id: "web-1", status: "running")
    await fake.setContainers([web1])
    let session = RuntimeSession(
        makeRuntime: { fake },
        pollInterval: .milliseconds(15), idleInterval: .milliseconds(80), unavailableInterval: .milliseconds(15)
    )

    // If `RuntimeSession.start()` ever started the poller before subscribing
    // `containers` to the bus, the poller's very first `.snapshot` publish
    // could race ahead of the store's subscribe and get silently dropped
    // forever (`EventBus.publish` doesn't replay for late subscribers) — the
    // store would then be stuck in `.connecting` no matter how long this
    // waits. This pins the ordering the whole pipeline depends on (see
    // `ContainerListStore.start()`'s doc comment), not just "does it
    // eventually load."
    await session.start()

    #expect(await waitUntil { session.containers.phase == .loaded([web1]) })

    await session.stop()
}

@MainActor
@Test func sessionOwnsResidentComposeSupervisionAndResumesRestartFromItsFirstSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root)
    let source = ComposeSource(
        yaml: """
        name: demo
        services:
          worker:
            image: worker
            restart: always
        """,
        fallbackName: "demo",
        workingDirectory: root.path,
        filePath: root.appendingPathComponent("compose.yaml").path
    )
    let document = try ComposeParser().parse(source: source)
    try store.saveProject(ProjectRecord(
        id: "demo",
        name: "demo",
        sourcePath: source.filePath!,
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    try store.saveResolvedProject(document, projectID: "demo")
    try store.saveState(StoredProjectState(
        revision: "revision",
        desiredRunning: true,
        serviceConfigHashes: ["worker": "hash"],
        services: [
            "worker": StoredServiceState(
                containerID: "demo-worker-1",
                desiredRunning: true
            ),
        ]
    ), projectID: "demo")

    let fake = FakeContainerRuntime()
    await fake.setContainers([
        ContainerSummary(
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
        ),
    ])
    let session = RuntimeSession(
        makeRuntime: { fake },
        projectStore: store,
        pollInterval: .milliseconds(15),
        idleInterval: .milliseconds(80),
        unavailableInterval: .milliseconds(15)
    )

    await session.start()

    #expect(await waitUntilAsync {
        await fake.calls.contains(.startContainer(id: "demo-worker-1"))
    })
    #expect(await waitUntil {
        session.composeSupervision.project("demo")?.services.first?.restart.attempts == 1
    })
    #expect(try store.loadState(projectID: "demo").services["worker"]?.restart.attempts == 1)

    await session.stop()
}

// MARK: - 6. MenuBarStore

@MainActor
@Test func menuBarStoreDerivesRuntimeUpAndRunningCountThroughTheSharedStore() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    let store = ContainerListStore(runtime: fake, events: bus)
    let menuBar = MenuBarStore(containers: store)

    #expect(menuBar.runtimeUp == false)
    #expect(menuBar.runningCount == 0)

    let web1 = makeWebContainer(id: "web-1", status: "running")
    let web2 = makeWebContainer(id: "web-2", status: "stopped")
    await fake.setContainers([web1, web2])
    await store.start()
    await poller.start()

    #expect(await waitUntil { menuBar.runtimeUp && menuBar.runningCount == 1 })

    await menuBar.stopAll()
    #expect(await fake.calls.contains(.stopContainer(id: "web-1", timeoutSeconds: nil)))

    await poller.stop()
    store.stop()
}

// MARK: - 7. B0 pass-through

@MainActor
@Test func gatewayPassesThroughSystemStartAndSystemStopAndTheFakeRecordsThem() async throws {
    let fake = FakeContainerRuntime()
    let gateway = RuntimeGateway(base: fake)

    try await gateway.systemStart()
    try await gateway.systemStop()

    #expect(await fake.calls == [.systemStart, .systemStop])
}

// MARK: - 8. RuntimeSession.makeDetailStore()

@MainActor
@Test func makeDetailStoreBuildsAWorkingStoreOnTheSharedPipeline() async throws {
    let fake = FakeContainerRuntime()
    await fake.setDetail(ContainerDetail(id: "web-1", status: "running", imageReference: "nginx"), forID: "web-1")
    let session = RuntimeSession(makeRuntime: { fake })

    let detailStore = session.makeDetailStore()
    #expect(detailStore != nil)

    await detailStore?.activate(id: "web-1")
    #expect(detailStore?.detail?.imageReference == "nginx")
}

@MainActor
@Test func makeDetailStoreReturnsNilWhenConstructionHitRuntimeMissing() async throws {
    let session = RuntimeSession(makeRuntime: { throw ProbeError(message: "container CLI not found") })

    #expect(session.makeDetailStore() == nil)
}

// MARK: - 9. currentContainers derivation

@MainActor
@Test func currentContainersMirrorsPhaseAcrossEveryCase() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    let store = ContainerListStore(runtime: fake, events: bus)

    #expect(store.currentContainers.isEmpty) // .connecting

    let web1 = makeWebContainer(id: "web-1", status: "running")
    await fake.setContainers([web1])
    await store.start()
    await poller.start()

    #expect(await waitUntil { store.currentContainers == [web1] })

    await fake.setError(ProbeError(message: "boom"), for: .listContainers)
    #expect(await waitUntil { store.currentContainers == [web1] }) // .unavailable keeps lastKnown

    await poller.stop()
    store.stop()
}

// MARK: - 10. RuntimeSession.makeImagesStore() / makeSystemStore()

@MainActor
@Test func makeImagesStoreAndMakeSystemStoreBuildWorkingStoresOnTheSharedPipeline() async throws {
    let fake = FakeContainerRuntime()
    await fake.setImages([ImageSummary(id: "img-1", reference: "nginx:latest")])
    let session = RuntimeSession(makeRuntime: { fake })

    let imagesStore = session.makeImagesStore()
    #expect(imagesStore != nil)
    await imagesStore?.refresh()
    #expect(imagesStore?.phase == .loaded([ImageSummary(id: "img-1", reference: "nginx:latest")]))

    let systemStore = session.makeSystemStore()
    #expect(systemStore != nil)
    await systemStore?.refresh()
    if case .loaded(let status, _) = systemStore?.phase {
        #expect(status.status == "running")
    } else {
        Issue.record("expected .loaded, got \(String(describing: systemStore?.phase))")
    }
}

@MainActor
@Test func makeImagesStoreAndMakeSystemStoreReturnNilWhenConstructionHitRuntimeMissing() async throws {
    let session = RuntimeSession(makeRuntime: { throw ProbeError(message: "container CLI not found") })

    #expect(session.makeImagesStore() == nil)
    #expect(session.makeSystemStore() == nil)
}
