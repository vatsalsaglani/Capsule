import AppCore
import ContainerClient
import ContainerClientTestSupport
import EventBus
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

private func makeSample(id: String, cpuUsageMicroseconds: UInt64) -> StatsSample {
    StatsSample(
        id: id,
        cpuUsageMicroseconds: cpuUsageMicroseconds,
        memoryUsageBytes: 10,
        memoryLimitBytes: 100,
        blockReadBytes: 0,
        blockWriteBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        processCount: 1
    )
}

/// A `ContainerRuntime` wrapping a `FakeContainerRuntime` that overrides only
/// `stats(ids:)` with a controllable, slow (never-finishing-on-its-own)
/// stream — `FakeContainerRuntime.stats` yields every preset tick and
/// finishes essentially synchronously, which can't exercise "stops consuming
/// *while the stream is still live*" the way `setStatsVisible(false)`/
/// `deactivate()` need to be tested (P1B B3 brief: "assert via fake calls or
/// stream teardown"). This forwards every other method to the wrapped fake
/// so it's otherwise a drop-in `ContainerRuntime`.
private actor SlowStatsRuntime: ContainerRuntime {
    private let base: FakeContainerRuntime
    private var terminated = false

    init(base: FakeContainerRuntime) { self.base = base }

    var statsStreamWasTornDown: Bool { terminated }

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

    func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        let id = ids.first ?? "unknown"
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [StatsSample].self)
        let tickTask = Task {
            var usec: UInt64 = 0
            while !Task.isCancelled {
                usec += 1_000_000
                continuation.yield([makeSample(id: id, cpuUsageMicroseconds: usec)])
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        continuation.onTermination = { [weak self] _ in
            tickTask.cancel()
            Task { await self?.markTerminated() }
        }
        return stream
    }

    private func markTerminated() { terminated = true }

    func listImages() async throws -> [ImageSummary] { try await base.listImages() }
    func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        try await base.pullImage(reference: reference, platform: platform)
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

// MARK: - 1. activate()/deactivate() lifecycle + detail refresh

@MainActor
@Test func activateLoadsDetailAndDeactivateClearsEverything() async throws {
    let fake = FakeContainerRuntime()
    let detail = ContainerDetail(id: "web-1", status: "running", imageReference: "nginx")
    await fake.setDetail(detail, forID: "web-1")
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "web-1")

    #expect(store.currentID == "web-1")
    #expect(store.detail == detail)
    #expect(store.detailError == nil)

    store.deactivate()

    #expect(store.currentID == nil)
    #expect(store.detail == nil)
    #expect(store.logLines.isEmpty)
    #expect(store.statsSeries.isEmpty)
}

@MainActor
@Test func activateRecordsAnInspectFailureWithoutThrowing() async throws {
    let fake = FakeContainerRuntime()
    // No detail stubbed for "missing" — `FakeContainerRuntime.inspectContainer`
    // throws `RuntimeError.commandFailed` for any unstubbed id.
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "missing")

    #expect(store.detail == nil)
    #expect(store.detailError != nil)
}

@MainActor
@Test func containerStateChangedForTheActiveIDTriggersARefresh() async throws {
    let fake = FakeContainerRuntime()
    let running = ContainerDetail(id: "web-1", status: "running", imageReference: "nginx")
    await fake.setDetail(running, forID: "web-1")
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "web-1")
    #expect(store.detail == running)

    let stopped = ContainerDetail(id: "web-1", status: "stopped", imageReference: "nginx")
    await fake.setDetail(stopped, forID: "web-1")
    await bus.publish(.containerStateChanged(
        ContainerSummary(id: "web-1", status: "stopped", imageReference: "nginx", addresses: []),
        previousStatus: "running"
    ))

    #expect(await waitUntil { store.detail == stopped })
    store.deactivate()
}

@MainActor
@Test func containerStateChangedForADifferentIDIsIgnored() async throws {
    let fake = FakeContainerRuntime()
    let running = ContainerDetail(id: "web-1", status: "running", imageReference: "nginx")
    await fake.setDetail(running, forID: "web-1")
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "web-1")
    await bus.publish(.containerStateChanged(
        ContainerSummary(id: "web-2", status: "stopped", imageReference: "redis", addresses: []),
        previousStatus: "running"
    ))

    try await Task.sleep(for: .milliseconds(40))
    #expect(store.detail == running)
    store.deactivate()
}

// MARK: - 2. Logs ring buffer

@MainActor
@Test func logLinesAreRingBufferedToTwoThousand() async throws {
    let fake = FakeContainerRuntime()
    await fake.setDetail(ContainerDetail(id: "web-1", status: "running"), forID: "web-1")
    let lines = (1...2500).map { LogLine(text: "line \($0)") }
    await fake.setLogLines(lines, forID: "web-1")
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "web-1")

    // Wait for the *final* line specifically, not just `count == 2000` — the
    // count transiently equals 2000 mid-drain (every append re-trims to the
    // cap), so polling on count alone can catch a still-in-progress window
    // instead of the fully-drained end state.
    #expect(await waitUntil { store.logLines.last?.text == "line 2500" })
    #expect(store.logLines.count == 2000)
    #expect(store.logLines.first?.text == "line 501")

    store.deactivate()
}

// MARK: - 3. Stats series + visibility gating

@MainActor
@Test func statsTicksPopulateTheSeriesOnlyOnceVisible() async throws {
    let fake = FakeContainerRuntime()
    await fake.setDetail(ContainerDetail(id: "web-1", status: "running"), forID: "web-1")
    await fake.setStatsTicks([
        [makeSample(id: "web-1", cpuUsageMicroseconds: 1_000_000)],
        [makeSample(id: "web-1", cpuUsageMicroseconds: 2_000_000)],
        [makeSample(id: "web-1", cpuUsageMicroseconds: 3_500_000)],
    ])
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: fake, events: bus)

    await store.activate(id: "web-1")
    try await Task.sleep(for: .milliseconds(40))
    #expect(store.statsSeries.isEmpty) // not visible yet — no stats(ids:) call made

    store.setStatsVisible(true)
    #expect(await waitUntil { store.statsSeries.count == 3 })
    #expect(store.cpuPercentSeries.count == 2)

    store.deactivate()
}

@MainActor
@Test func setStatsVisibleFalseTearsDownTheLiveStatsStream() async throws {
    let fake = FakeContainerRuntime()
    await fake.setDetail(ContainerDetail(id: "web-1", status: "running"), forID: "web-1")
    let slow = SlowStatsRuntime(base: fake)
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: slow, events: bus)

    await store.activate(id: "web-1")
    store.setStatsVisible(true)
    #expect(await waitUntil { store.statsSeries.count >= 2 })

    store.setStatsVisible(false)

    var tornDown = false
    for _ in 0..<50 {
        tornDown = await slow.statsStreamWasTornDown
        if tornDown { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(tornDown)

    let countAfterStop = store.statsSeries.count
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.statsSeries.count == countAfterStop)

    store.deactivate()
}

@MainActor
@Test func deactivateTearsDownTheLiveStatsStream() async throws {
    let fake = FakeContainerRuntime()
    await fake.setDetail(ContainerDetail(id: "web-1", status: "running"), forID: "web-1")
    let slow = SlowStatsRuntime(base: fake)
    let bus = EventBus<RuntimeEvent>()
    let store = ContainerDetailStore(runtime: slow, events: bus)

    await store.activate(id: "web-1")
    store.setStatsVisible(true)
    #expect(await waitUntil { store.statsSeries.count >= 2 })

    store.deactivate()

    var tornDown = false
    for _ in 0..<50 {
        tornDown = await slow.statsStreamWasTornDown
        if tornDown { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(tornDown)
    #expect(store.statsSeries.isEmpty)
}

// MARK: - 4. Pure functions: browserURL

@MainActor
@Test func browserURLResolvesNilOrAllInterfacesHostToLocalhost() {
    let store = ContainerDetailStore(runtime: FakeContainerRuntime(), events: EventBus<RuntimeEvent>())

    #expect(store.browserURL(for: PortMapping(hostPort: 8080, containerPort: 80)) == URL(string: "http://localhost:8080"))
    #expect(
        store.browserURL(for: PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80))
            == URL(string: "http://localhost:8080")
    )
}

@MainActor
@Test func browserURLUsesASpecificBoundHostAddressVerbatim() {
    let store = ContainerDetailStore(runtime: FakeContainerRuntime(), events: EventBus<RuntimeEvent>())

    #expect(
        store.browserURL(for: PortMapping(hostAddress: "192.168.1.5", hostPort: 3000, containerPort: 3000))
            == URL(string: "http://192.168.1.5:3000")
    )
}

@MainActor
@Test func browserURLReturnsNilForUDPPublishedPorts() {
    let store = ContainerDetailStore(runtime: FakeContainerRuntime(), events: EventBus<RuntimeEvent>())

    #expect(store.browserURL(for: PortMapping(hostPort: 53, containerPort: 53, proto: .udp)) == nil)
}

// MARK: - 5. Pure functions: cpuPercent

@Test func cpuPercentDerivesFromTheDeltaOverElapsedWallTime() {
    let start = Date()
    let previous = StatsPoint(sample: makeSample(id: "x", cpuUsageMicroseconds: 1_000_000), receivedAt: start)
    let current = StatsPoint(
        sample: makeSample(id: "x", cpuUsageMicroseconds: 1_500_000),
        receivedAt: start.addingTimeInterval(1)
    )

    #expect(ContainerDetailStore.cpuPercent(current: current, previous: previous) == 50.0)
}

@Test func cpuPercentIsNilWhenElapsedTimeIsNotPositive() {
    let start = Date()
    let point = StatsPoint(sample: makeSample(id: "x", cpuUsageMicroseconds: 1_000_000), receivedAt: start)

    #expect(ContainerDetailStore.cpuPercent(current: point, previous: point) == nil)
}

@Test func cpuPercentIsNilWhenTheCounterWentBackwards() {
    let start = Date()
    let previous = StatsPoint(sample: makeSample(id: "x", cpuUsageMicroseconds: 2_000_000), receivedAt: start)
    let current = StatsPoint(
        sample: makeSample(id: "x", cpuUsageMicroseconds: 1_000_000),
        receivedAt: start.addingTimeInterval(1)
    )

    #expect(ContainerDetailStore.cpuPercent(current: current, previous: previous) == nil)
}
