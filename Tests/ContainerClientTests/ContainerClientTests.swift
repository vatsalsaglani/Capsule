import Foundation
import Testing
@testable import ContainerClient

@Test func subprocessCapturesStdout() async throws {
    let result = try await Subprocess.run(executablePath: "/bin/echo", arguments: ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.stdoutText == "hello\n")
    #expect(result.stderr.isEmpty)
}

@Test func subprocessCapturesStderrAndExitCode() async throws {
    // /bin/sh is the executable under test here, invoked with an argv array —
    // production code never routes through a shell (plan §2.2).
    let result = try await Subprocess.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo oops 1>&2; exit 3"]
    )
    #expect(result.exitCode == 3)
    #expect(result.stderrText == "oops\n")
}

@Test func subprocessTimesOutAndTerminates() async throws {
    await #expect(throws: SubprocessError.self) {
        _ = try await Subprocess.run(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(200)
        )
    }
}

@Test func subprocessRejectsMissingExecutable() async throws {
    await #expect(throws: SubprocessError.self) {
        _ = try await Subprocess.run(executablePath: "/no/such/binary", arguments: [])
    }
}

@Test func semanticVersionParsesRealVersionLine() {
    let line = "container CLI version 1.1.0 (build: release, commit: 5973b9c)"
    #expect(SemanticVersion(firstIn: line) == SemanticVersion(major: 1, minor: 1, patch: 0))
    #expect(SemanticVersion(firstIn: "no version here") == nil)
}

@Test func semanticVersionOrdering() {
    #expect(SemanticVersion(major: 1, minor: 2, patch: 0) > SemanticVersion(major: 1, minor: 1, patch: 9))
    #expect(SemanticVersion(major: 2, minor: 0, patch: 0) > SemanticVersion(major: 1, minor: 99, patch: 99))
}

@Test func containerSummaryDecodesObservedJSONShape() throws {
    // Mirrors the nested-configuration lowerCamelCase shape observed from
    // `container image list --format json` v1.1.0 — re-verify for `list`
    // in spike S2 (docs/learnings/2026-07-12-runtime-cli-observations.md).
    let json = Data("""
    [
      {
        "status": "running",
        "configuration": {
          "id": "my-web",
          "image": { "reference": "docker.io/library/nginx:latest" }
        },
        "networks": [
          { "network": "default", "address": "192.168.64.3/24" }
        ]
      },
      {
        "configuration": { "id": "bare-minimum" }
      }
    ]
    """.utf8)
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: json)
    #expect(summaries.count == 2)
    #expect(summaries[0].id == "my-web")
    #expect(summaries[0].runState == .running)
    #expect(summaries[0].imageReference == "docker.io/library/nginx:latest")
    #expect(summaries[0].addresses == ["192.168.64.3/24"])
    #expect(summaries[1].id == "bare-minimum")
    #expect(summaries[1].runState == .unknown)
}
