import ContainerClient
import ContainerClientTestSupport
import Diagnostics
import Foundation
import Testing

private struct DiagnosticFixtureError: Error, Sendable {}

private func finalSnapshot(from provider: RuntimeDiagnosticsProviding) async -> DiagnosticsSnapshot? {
    var final: DiagnosticsSnapshot?
    for await snapshot in provider.snapshots(for: .standard) {
        final = snapshot
    }
    return final
}

@Test func diagnosticsMissingBinaryFailsAndSkipsDependentChecks() async {
    let provider = RuntimeDiagnostics(
        locateBinary: { nil },
        makeRuntime: { throw DiagnosticFixtureError() },
        fetchLatestRelease: { throw DiagnosticFixtureError() }
    )

    let snapshot = await finalSnapshot(from: provider)

    #expect(snapshot?.overall == .failed)
    #expect(snapshot?.checks.first(where: { $0.id == .binary })?.status == .failed)
    #expect(snapshot?.checks.first(where: { $0.id == .version })?.status == .skipped)
    #expect(snapshot?.checks.first(where: { $0.id == .runtimeStatus })?.status == .skipped)
}

@Test func diagnosticsHealthyRuntimeProducesReadyFinalSnapshot() async {
    let runtime = FakeContainerRuntime()
    let provider = RuntimeDiagnostics(
        locateBinary: { "/usr/local/bin/container" },
        makeRuntime: { runtime },
        fetchLatestRelease: {
            GitHubRelease(
                tagName: "1.1.0",
                htmlURL: URL(string: "https://github.com/apple/container/releases/tag/1.1.0")!
            )
        }
    )

    let snapshot = await finalSnapshot(from: provider)

    #expect(snapshot?.completedAt != nil)
    #expect(snapshot?.overall == .ready)
    #expect((snapshot?.checks.allSatisfy { $0.status == .passed }) == true)
}

@Test func diagnosticsStoppedRuntimeAndNewReleaseNeedAction() async {
    let runtime = FakeContainerRuntime()
    await runtime.setSystemStatus(SystemStatus(status: "stopped"))
    let provider = RuntimeDiagnostics(
        locateBinary: { "/usr/local/bin/container" },
        makeRuntime: { runtime },
        fetchLatestRelease: {
            GitHubRelease(
                tagName: "1.2.0",
                htmlURL: URL(string: "https://github.com/apple/container/releases/tag/1.2.0")!
            )
        }
    )

    let snapshot = await finalSnapshot(from: provider)

    #expect(snapshot?.overall == .needsAction)
    #expect(snapshot?.checks.first(where: { $0.id == .runtimeStatus })?.status == .warning)
    #expect(snapshot?.checks.first(where: { $0.id == .update })?.status == .warning)
}

@Test func diagnosticsRejectsUnsupportedRuntimeMajor() async {
    let runtime = FakeContainerRuntime()
    await runtime.setCLIVersion(.init(major: 2, minor: 0, patch: 0))
    let provider = RuntimeDiagnostics(
        locateBinary: { "/usr/local/bin/container" },
        makeRuntime: { runtime },
        fetchLatestRelease: { throw DiagnosticFixtureError() }
    )

    let snapshot = await finalSnapshot(from: provider)

    #expect(snapshot?.overall == .failed)
    #expect(snapshot?.checks.first(where: { $0.id == .version })?.status == .failed)
}
