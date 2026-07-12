import Foundation
import Testing
@testable import ContainerClient

/// A tiny order-recording `ContainerRuntime` double, purpose-built for
/// exercising `RuntimeGateway`'s serialization: each call records a
/// `"<label>.begin"`/`"<label>.end"` pair with an artificial delay in
/// between, so tests can assert whether two concurrent calls interleaved
/// (overlapped) or were strictly ordered (one fully finished before the next
/// began).
private actor OrderRecordingRuntime: ContainerRuntime {
    private(set) var events: [String] = []
    private var delay: Duration = .milliseconds(60)

    func setDelay(_ duration: Duration) {
        delay = duration
    }

    private func perform<T: Sendable>(_ label: String, _ result: @Sendable () -> T) async -> T {
        events.append("\(label).begin")
        try? await Task.sleep(for: delay)
        let value = result()
        events.append("\(label).end")
        return value
    }

    // MARK: - Exercised by the gateway tests

    func listContainers(all: Bool) async throws -> [ContainerSummary] {
        await perform("list") { [] }
    }

    func createContainer(_ spec: RunSpec) async throws -> String {
        await perform("create(\(spec.name ?? "?"))") { spec.name ?? "auto" }
    }

    func startContainer(id: String) async throws {
        _ = await perform("start(\(id))") { () }
    }

    func stopContainer(id: String, timeoutSeconds: Int?) async throws {
        _ = await perform("stop(\(id))") { () }
    }

    func deleteContainer(id: String, force: Bool) async throws {
        _ = await perform("delete(\(id))") { () }
    }

    // MARK: - Unexercised protocol requirements (trivial stubs)

    func cliVersion() async throws -> SemanticVersion { SemanticVersion(major: 1, minor: 1, patch: 0) }
    func systemStatus() async throws -> SystemStatus { SystemStatus(status: "running") }
    func systemDiskUsage() async throws -> SystemDiskUsage {
        let empty = ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0)
        return SystemDiskUsage(containers: empty, images: empty, volumes: empty)
    }
    func systemStart() async throws {}
    func systemStop() async throws {}
    func inspectContainer(id: String) async throws -> ContainerDetail { ContainerDetail(id: id, status: "running") }
    func killContainer(id: String, signal: String) async throws {}
    func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LogLine.self)
        continuation.finish()
        return stream
    }
    func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [StatsSample].self)
        continuation.finish()
        return stream
    }
    func listImages() async throws -> [ImageSummary] { [] }
    func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PullProgress.self)
        continuation.finish()
        return stream
    }
    func deleteImage(reference: String) async throws {}
    func tagImage(source: String, target: String) async throws {}
    func listVolumes() async throws -> [VolumeSummary] { [] }
    func createVolume(name: String, labels: [String: String]) async throws {}
    func deleteVolume(name: String) async throws {}
    func listNetworks() async throws -> [NetworkSummary] { [] }
    func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {}
    func deleteNetwork(name: String) async throws {}
}

@Test func gatewaySameIDMutationsAreStrictlyOrderedNeverInterleaved() async throws {
    let recorder = OrderRecordingRuntime()
    await recorder.setDelay(.milliseconds(80))
    let gateway = RuntimeGateway(base: recorder)

    async let startCall: () = gateway.startContainer(id: "a")
    async let stopCall: () = gateway.stopContainer(id: "a", timeoutSeconds: nil)
    _ = try await (startCall, stopCall)

    let events = await recorder.events
    let startsFirst: [String] = ["start(a).begin", "start(a).end", "stop(a).begin", "stop(a).end"]
    let stopsFirst: [String] = ["stop(a).begin", "stop(a).end", "start(a).begin", "start(a).end"]
    #expect(events == startsFirst || events == stopsFirst)
}

@Test func gatewayDifferentIDMutationsOverlapConcurrently() async throws {
    let recorder = OrderRecordingRuntime()
    await recorder.setDelay(.milliseconds(80))
    let gateway = RuntimeGateway(base: recorder)

    async let startA: () = gateway.startContainer(id: "a")
    async let startB: () = gateway.startContainer(id: "b")
    _ = try await (startA, startB)

    let events = await recorder.events
    // Both begin before either ends — proof they ran concurrently rather
    // than being serialized behind one another.
    #expect(Set(events.prefix(2)) == Set(["start(a).begin", "start(b).begin"]))
}

@Test func gatewayReadsOverlapAPendingMutation() async throws {
    let recorder = OrderRecordingRuntime()
    await recorder.setDelay(.milliseconds(80))
    let gateway = RuntimeGateway(base: recorder)

    async let mutation: () = gateway.startContainer(id: "a")
    async let read: [ContainerSummary] = gateway.listContainers(all: true)
    _ = try await (mutation, read)

    let events = await recorder.events
    // The read's `begin` must land before the pending mutation's `end` —
    // proof reads are never queued behind mutations.
    let mutationEndIndex = events.firstIndex(of: "start(a).end")!
    let readBeginIndex = events.firstIndex(of: "list.begin")!
    #expect(readBeginIndex < mutationEndIndex)
}

@Test func gatewayCancelledWaiterDoesNotWedgeTheLane() async throws {
    let recorder = OrderRecordingRuntime()
    await recorder.setDelay(.milliseconds(120))
    let gateway = RuntimeGateway(base: recorder)

    // op1 claims the "a" lane.
    let op1 = Task { try await gateway.startContainer(id: "a") }
    try await Task.sleep(for: .milliseconds(20))

    // op2 queues behind op1, then gets cancelled almost immediately — this
    // must not corrupt the lane's bookkeeping or leave it wedged.
    let op2 = Task { try await gateway.stopContainer(id: "a", timeoutSeconds: nil) }
    try await Task.sleep(for: .milliseconds(20))
    op2.cancel()

    try await op1.value
    _ = try? await op2.value

    // A subsequent call on the same lane must complete promptly — proof the
    // cancelled waiter's tail was cleaned up rather than left stuck.
    try await gateway.deleteContainer(id: "a", force: false)

    let events = await recorder.events
    #expect(events.contains("delete(a).end"))
}
