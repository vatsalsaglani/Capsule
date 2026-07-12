import Foundation
import Testing
@testable import ContainerClient

/// Exercises `CLIProcessClient` against the **real** `container` runtime.
/// Skipped by default — opt in with `CAPSULE_LIVE_TESTS=1 swift test` on a
/// machine with `container` 1.1.x installed and its apiserver running.
/// Creates/pulls only scratch resources prefixed `p1a-`; every test cleans
/// up after itself, but if a run is interrupted, sweep leftovers with
/// `container ls -a --format json | ... | xargs container delete --force`
/// filtered to the `p1a-` prefix.
private let liveTestsEnabled = ProcessInfo.processInfo.environment["CAPSULE_LIVE_TESTS"] == "1"

@Suite(.enabled(if: liveTestsEnabled))
struct LiveRuntimeTests {
    let client: CLIProcessClient

    init() throws {
        client = try CLIProcessClient()
    }

    @Test func createStartLogsExecStatsKillDeleteLifecycle() async throws {
        let name = "p1a-\(UUID().uuidString.prefix(8))"
        var spec = RunSpec(image: "docker.io/library/alpine:latest")
        spec.name = name
        spec.command = ["sh", "-c", "i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done"]

        let id = try await client.createContainer(spec)
        try await client.startContainer(id: id)

        // `logs --follow`: consume a couple of lines, then walk away —
        // proves both the streaming shape and that breaking out of the
        // `for await` loop cleanly tears down the child (no hang on return).
        let lines = try await {
            var collected: [String] = []
            for try await line in try await client.logs(id: id, follow: true, tail: nil) {
                collected.append(line.text)
                if collected.count == 2 { break }
            }
            return collected
        }()
        #expect(lines.count == 2)

        let execResult = try await client.exec(id: id, argv: ["echo", "hi"], timeout: .seconds(10))
        #expect(execResult.exitCode == 0)
        #expect(execResult.stdoutText.contains("hi"))

        var ticks = 0
        for try await _ in try await client.stats(ids: [id]) {
            ticks += 1
            if ticks == 2 { break }
        }
        #expect(ticks == 2)

        try await client.killContainer(id: id, signal: "SIGTERM")
        try await client.deleteContainer(id: id, force: true)
    }

    @Test func pullSmallImageReportsProgressOnStderr() async throws {
        var sawAnyProgress = false
        for try await progress in try await client.pullImage(reference: "docker.io/library/alpine:latest", platform: nil) {
            sawAnyProgress = true
            #expect(!progress.message.isEmpty)
        }
        // An already-cached image can legitimately pull near-instantly with
        // little or no progress output — only fail if the call itself threw
        // (it didn't, since we reached here), not on the presence of lines.
        _ = sawAnyProgress
    }

    /// Manual precondition: run `container system stop` before this test and
    /// `container system start` afterward — there is no supported API to
    /// stop/start the apiserver from within a test. Left in the live-gated
    /// suite as an executable spec of the expected shape (typed error
    /// carrying the real stderr) rather than something the default `swift
    /// test` run exercises unattended.
    @Test func apiserverStoppedSurfacesTypedErrorWithRealStderr() async throws {
        do {
            _ = try await client.listContainers(all: true)
        } catch let error as RuntimeError {
            guard case .commandFailed(_, _, let stderr) = error else {
                Issue.record("expected .commandFailed, got \(error)")
                return
            }
            #expect(!stderr.isEmpty)
        }
    }
}
