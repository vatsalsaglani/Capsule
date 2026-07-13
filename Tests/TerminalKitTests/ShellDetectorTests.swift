import ContainerClient
import Foundation
import Testing
@testable import TerminalKit

/// Per-argv `ContainerRuntime` double (cf.
/// `Tests/ContainerClientTests/RuntimeGatewayTests.swift`'s
/// `OrderRecordingRuntime`): the shared `FakeContainerRuntime` keys `exec`
/// results by container id only, which can't express "this shell succeeds,
/// that one doesn't" for the same container — this fake keys by the probed
/// command instead.
private actor ArgvKeyedExecRuntime: ContainerRuntime {
    private var exitCodeByFirstArgv: [String: Int32]
    private(set) var probedArgv: [[String]] = []

    init(exitCodeByFirstArgv: [String: Int32]) {
        self.exitCodeByFirstArgv = exitCodeByFirstArgv
    }

    func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        probedArgv.append(argv)
        let shell = argv.first ?? ""
        let exitCode = exitCodeByFirstArgv[shell] ?? 127
        return ExecResult(exitCode: exitCode, stdout: Data(), stderr: Data())
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
    func listContainers(all: Bool) async throws -> [ContainerSummary] { [] }
    func inspectContainer(id: String) async throws -> ContainerDetail { ContainerDetail(id: id, status: "running") }
    func createContainer(_ spec: RunSpec) async throws -> String { "id" }
    func startContainer(id: String) async throws {}
    func stopContainer(id: String, timeoutSeconds: Int?) async throws {}
    func killContainer(id: String, signal: String) async throws {}
    func deleteContainer(id: String, force: Bool) async throws {}
    func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LogLine.self)
        continuation.finish()
        return stream
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

@Test func shellDetectorPicksFirstSuccessInOrder() async throws {
    // alpine-shaped: no bash, `sh` (busybox) works.
    let runtime = ArgvKeyedExecRuntime(exitCodeByFirstArgv: ["sh": 0, "ash": 0])
    let shell = try await ShellDetector.detectShell(containerID: "c1", runtime: runtime)
    #expect(shell == "sh")
    let probed = await runtime.probedArgv
    #expect(probed.first?.first == "sh")
}

@Test func shellDetectorFallsBackWhenEarlierCandidatesFail() async throws {
    // Only `ash` works — `sh` and `bash` both fail (unusual, but exercises
    // the full fallback chain end to end).
    let runtime = ArgvKeyedExecRuntime(exitCodeByFirstArgv: ["ash": 0])
    let shell = try await ShellDetector.detectShell(containerID: "c1", runtime: runtime)
    #expect(shell == "ash")
    let probed = await runtime.probedArgv
    #expect(probed.map(\.first) == ["sh", "bash", "ash"])
}

@Test func shellDetectorThrowsNamingEveryCandidateTriedWhenAllFail() async throws {
    let runtime = ArgvKeyedExecRuntime(exitCodeByFirstArgv: [:])
    do {
        _ = try await ShellDetector.detectShell(containerID: "c1", runtime: runtime)
        Issue.record("expected detectShell to throw when no shell is usable")
    } catch let error as ShellDetector.DetectionError {
        #expect(error == .noShellFound(containerID: "c1", tried: ["sh", "bash", "ash"]))
    }
}
