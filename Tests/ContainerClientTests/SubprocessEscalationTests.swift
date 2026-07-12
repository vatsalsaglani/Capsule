import Foundation
import Testing
@testable import ContainerClient

/// Plan spike S5's decision (`docs/learnings/2026-07-13-build-cancellation.md`):
/// SIGTERM → grace → SIGKILL, general defense-in-depth for every
/// `Subprocess`-spawned child.
@Test func subprocessEscalatesToSIGKILLWhenTERMIsIgnored() async throws {
    let marker = UUID().uuidString
    let clock = ContinuousClock()
    let start = clock.now

    let task = Task {
        try await Subprocess.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; : '\(marker)'; echo up; sleep 30"],
            killEscalationGrace: .milliseconds(200)
        )
    }

    // Let the child install its TERM trap before cancelling.
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()

    await #expect(throws: (any Error).self) {
        _ = try await task.value
    }

    // Escalation (200ms grace + a small margin) must have brought this down
    // well under the process's own 30s sleep — proves SIGKILL fired rather
    // than the cancellation just hanging until the child's own timeout.
    let elapsed = clock.now - start
    #expect(elapsed < .seconds(2))

    // The *direct* child (`sh`, which carries the marker in its own `-c`
    // argument) is gone — this does NOT prove the orphaned `sleep 30`
    // grandchild is gone too (it never carries the marker in its own argv,
    // since it's invoked as bare `sleep 30`; see docs/learnings/
    // 2026-07-13-p1a-implementation-notes.md for why that grandchild can
    // outlive the direct child by design of this fallback). The marker
    // makes this pgrep specific to *this* test's `sh` process, not any
    // other concurrently-running test's. Bracketing the first character
    // keeps the search pattern itself from self-matching the invoking
    // `pgrep` process's own argv.
    let bracketedMarker = "[\(marker.first!)]\(marker.dropFirst())"
    let check = try await Subprocess.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "pgrep -f '\(bracketedMarker)' | wc -l | tr -d ' '"]
    )
    #expect(check.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
}

/// The pre-existing timeout path (not driven by external cancellation) must
/// keep working unchanged now that `killEscalationGrace` exists.
@Test func subprocessTimeoutPathStillTerminatesPromptly() async throws {
    let clock = ContinuousClock()
    let start = clock.now

    await #expect(throws: SubprocessError.self) {
        _ = try await Subprocess.run(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(200)
        )
    }

    // `/bin/sleep` honors plain SIGTERM immediately (no trap), so this
    // should resolve near the 200ms timeout, not the 5s default grace.
    let elapsed = clock.now - start
    #expect(elapsed < .seconds(2))
}
