import Foundation
import Testing
@testable import ContainerClient

@Test func lineStreamYieldsMultipleLinesInOrder() async throws {
    let stream = try SubprocessLineStream.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo one; echo two; echo three"],
        commandDescription: "test multi-line",
        readFrom: .stdout,
        bufferingPolicy: .unbounded,
        transform: { $0 }
    )
    var lines: [String] = []
    for try await line in stream { lines.append(line) }
    #expect(lines == ["one", "two", "three"])
}

@Test func lineStreamHandlesPartialChunksCRLFAndNoTrailingNewline() async throws {
    // `sleep 0.05` between writes forces the reader to observe separate
    // partial reads rather than one single buffered chunk; the final
    // `printf` (no trailing `\n`) exercises the no-terminator-at-EOF case,
    // and the embedded `\r\n` exercises CRLF splitting.
    let stream = try SubprocessLineStream.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "printf 'alpha\\r\\n'; sleep 0.05; printf 'beta\\n'; sleep 0.05; printf 'gamma'"],
        commandDescription: "test partial chunks",
        readFrom: .stdout,
        bufferingPolicy: .unbounded,
        transform: { $0 }
    )
    var lines: [String] = []
    for try await line in stream { lines.append(line) }
    #expect(lines == ["alpha", "beta", "gamma"])
}

@Test func lineStreamThrowsWithOtherFDTailOnNonZeroExit() async throws {
    let stream = try SubprocessLineStream.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo out-line; echo err-line 1>&2; exit 3"],
        commandDescription: "container test-command",
        readFrom: .stdout,
        bufferingPolicy: .unbounded,
        transform: { $0 }
    )
    var lines: [String] = []
    do {
        for try await line in stream { lines.append(line) }
        Issue.record("expected the stream to throw on a non-zero exit")
    } catch let error as RuntimeError {
        guard case .commandFailed(let command, let exitCode, let stderr) = error else {
            Issue.record("unexpected RuntimeError case: \(error)")
            return
        }
        #expect(command == "container test-command")
        #expect(exitCode == 3)
        #expect(stderr == "err-line")
    }
    #expect(lines == ["out-line"])
}

@Test func lineStreamConsumerCancelKillsTheChildPromptly() async throws {
    // A single-process busy-wait that ignores SIGTERM and never forks —
    // unlike a subshell spawning a `sleep` grandchild, killing this process
    // directly closes its own stdout, so escalation alone (no coordinator
    // fallback machinery) is enough. Matches the real shape of what
    // `SubprocessLineStream` actually wraps (`logs -f`, `image pull`): a
    // single compiled binary, not a shell forking descendants.
    let marker = UUID().uuidString
    let clock = ContinuousClock()
    let start = clock.now

    let stream = try SubprocessLineStream.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "trap '' TERM; : '\(marker)'; echo up; while true; do :; done"],
        commandDescription: "test cancel",
        readFrom: .stdout,
        bufferingPolicy: .unbounded,
        killEscalationGrace: .milliseconds(200),
        transform: { $0 }
    )

    let consumeTask = Task {
        for try await _ in stream {
            // Keep consuming until externally cancelled.
        }
    }

    // Let the child install its trap and start spinning before cancelling.
    try await Task.sleep(for: .milliseconds(150))
    consumeTask.cancel()
    // `AsyncThrowingStream` treats consumer cancellation as immediate
    // termination of the *iteration* (that's what fires `onTermination` in
    // the first place) — so `consumeTask.value` resolves right away,
    // independent of whether the child process has actually died yet. Wait
    // out the escalation's own timeline (grace + a margin) before checking
    // that the process is gone.
    _ = try? await consumeTask.value

    let elapsed = clock.now - start
    #expect(elapsed < .seconds(2))

    try await Task.sleep(for: .milliseconds(600))

    // The classic `pgrep -f` self-match trick: bracketing the first
    // character makes the search *pattern* itself not match the invoking
    // `pgrep` process's own argv (which contains the unbracketed marker).
    let bracketedMarker = "[\(marker.first!)]\(marker.dropFirst())"
    let check = try await Subprocess.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "pgrep -f '\(bracketedMarker)' | wc -l | tr -d ' '"]
    )
    #expect(check.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
}
