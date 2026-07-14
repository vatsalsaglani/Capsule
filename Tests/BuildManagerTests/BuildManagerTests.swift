import BuildManager
import ContainerClient
import ContainerClientTestSupport
import Foundation
import Testing

@Test func buildRequestResolverDetectsDockerfileAndRedactsArgumentValuesFromHistory() async throws {
    let root = try temporaryDirectory(prefix: "build-resolver")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("FROM scratch\n".utf8).write(to: root.appending(path: "Dockerfile"))

    let runtime = FakeContainerRuntime()
    await runtime.setBuildEvents(
        [BuildProgress(message: "#1 TOKEN=must-not-be-persisted")],
        forTag: "example/app:dev"
    )
    let history = BuildHistoryStore(rootDirectory: root.appending(path: "history"))
    let center = BuildCenter(runtime: runtime, historyStore: history)
    let execution = try await center.start(BuildRequest(
        contextDirectory: root,
        tags: ["example/app:dev", "example/app:latest"],
        arguments: ["TOKEN": "must-not-be-persisted"]
    ))

    var final: BuildRecord?
    for await event in execution.events {
        if case .finished(let record) = event { final = record }
    }

    #expect(final?.state == .succeeded)
    #expect(final?.request.argumentKeys == ["TOKEN"])
    #expect(final?.request.tags == ["example/app:dev", "example/app:latest"])
    #expect(final?.output.map(\.message) == ["#1 TOKEN=<redacted>"])
    let encoded = try Data(contentsOf: root.appending(path: "history/history.json"))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("must-not-be-persisted"))
    let calls = await runtime.calls
    #expect(calls.contains { if case .buildImage = $0 { true } else { false } })
    #expect(calls.contains(.tagImage(source: "example/app:dev", target: "example/app:latest")))
}

@Test func buildRequestResolverFailsLoudlyWithoutDockerfileOrTag() throws {
    let root = try temporaryDirectory(prefix: "build-invalid")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: BuildRequestError.self) {
        try BuildRequestResolver.resolve(BuildRequest(contextDirectory: root, tags: ["tag"]))
    }
    try Data("FROM scratch\n".utf8).write(to: root.appending(path: "Dockerfile"))
    #expect(throws: BuildRequestError.self) {
        try BuildRequestResolver.resolve(BuildRequest(contextDirectory: root, tags: []))
    }
}

@Test func buildHistoryRecoversAnInterruptedRunningRecord() async throws {
    let root = try temporaryDirectory(prefix: "build-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BuildHistoryStore(rootDirectory: root)
    let record = BuildRecord(
        id: BuildID(),
        request: BuildRequestSummary(
            contextPath: "/tmp/context",
            dockerfilePath: "/tmp/context/Dockerfile",
            tags: ["example:test"],
            argumentKeys: [],
            target: nil,
            platform: nil,
            cachePolicy: .useCache,
            baseImagePolicy: .useLocal
        )
    )
    try await store.upsert(record)

    let reopened = BuildHistoryStore(rootDirectory: root)
    let recovered = try await reopened.records()
    #expect(recovered.first?.state == .failed)
    #expect(recovered.first?.failureMessage?.contains("frontend exited") == true)
}

@Test func buildCenterSerializesBuilderResetThroughTypedRuntimeCalls() async throws {
    let root = try temporaryDirectory(prefix: "builder-reset")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = FakeContainerRuntime()
    let center = BuildCenter(
        runtime: runtime,
        historyStore: BuildHistoryStore(rootDirectory: root)
    )
    let configuration = BuilderConfiguration(cpus: 4, memoryBytes: 8_589_934_592)

    try await center.resetBuilder(configuration)

    #expect(await runtime.calls == [
        .deleteBuilder(force: true),
        .startBuilder(configuration),
    ])
}

private func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "capsule-\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
