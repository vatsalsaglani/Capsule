import AppCore
import ContainerClient
import ContainerClientTestSupport
import Testing

@MainActor
@Test func metricsStorePublishesOnlyRequestedContainersAndTotalsMemory() async throws {
    let runtime = FakeContainerRuntime()
    let web = StatsSample(
        id: "web-1",
        cpuUsageMicroseconds: 10,
        memoryUsageBytes: 128,
        memoryLimitBytes: 1_024,
        blockReadBytes: 0,
        blockWriteBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        processCount: 2
    )
    let unrelated = StatsSample(
        id: "other-1",
        cpuUsageMicroseconds: 20,
        memoryUsageBytes: 512,
        memoryLimitBytes: 1_024,
        blockReadBytes: 0,
        blockWriteBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        processCount: 1
    )
    await runtime.setStatsTicks([[web, unrelated]])
    let store = ContainerMetricsStore(runtime: runtime)

    await store.observe(ids: ["web-1"])

    #expect(store.sample(for: "web-1") == web)
    #expect(store.sample(for: "other-1") == nil)
    #expect(store.totalMemoryUsageBytes == 128)
    #expect(await runtime.calls == [.stats(ids: ["web-1"])])
}

@MainActor
@Test func metricsStoreClearsSamplesWhenNoContainersAreVisible() async {
    let runtime = FakeContainerRuntime()
    await runtime.setStatsTicks([[
        StatsSample(
            id: "web-1",
            cpuUsageMicroseconds: 10,
            memoryUsageBytes: 128,
            memoryLimitBytes: 1_024,
            blockReadBytes: 0,
            blockWriteBytes: 0,
            networkReceivedBytes: 0,
            networkSentBytes: 0,
            processCount: 2
        ),
    ]])
    let store = ContainerMetricsStore(runtime: runtime)

    await store.observe(ids: ["web-1"])
    await store.observe(ids: [])

    #expect(store.latestByID.isEmpty)
    #expect(!store.isCollecting)
}
