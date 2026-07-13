import Darwin
import Foundation
import Testing
@testable import TerminalKit

/// Isolates the accumulated text so the reader task and the timeout task in
/// `collectOutput` below can share it without a data race — a plain
/// captured `var` shared between two concurrent `TaskGroup` children isn't
/// `Sendable`-safe (compiler-enforced), so this is the actor-based fix
/// rather than reaching for `@unchecked Sendable`.
private actor OutputAccumulator {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

/// Collects decoded UTF-8 text from `stream` until `predicate` matches the
/// accumulated text or `timeout` elapses (swift-concurrency-pro `testing.md`:
/// poll/await real async events rather than a fixed sleep-then-assert-once).
private func collectOutput(
    from stream: AsyncStream<Data>,
    until predicate: @escaping @Sendable (String) -> Bool,
    timeout: Duration = .seconds(5)
) async -> String {
    let accumulator = OutputAccumulator()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await chunk in stream {
                await accumulator.append(String(decoding: chunk, as: UTF8.self))
                if predicate(await accumulator.text) { return }
            }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
        }
        await group.next()
        group.cancelAll()
    }
    return await accumulator.text
}

@Test func echoRoundTrip() async throws {
    let session = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-i"])
    await session.send(Data("echo HELLO-ROUNDTRIP\n".utf8))
    let output = await collectOutput(from: session.output) { $0.contains("HELLO-ROUNDTRIP") }
    #expect(output.contains("HELLO-ROUNDTRIP"))
    await session.terminate()
}

@Test func waitUntilExitReportsShellExitCode() async throws {
    let session = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-c", "exit 7"])
    let code = await session.waitUntilExit()
    #expect(code == 7)
}

@Test func resizePropagatesToChildViaSttySize() async throws {
    let session = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-i"])
    await session.resize(columns: 100, rows: 40)
    await session.send(Data("stty size\n".utf8))
    let output = await collectOutput(from: session.output) { $0.contains("40 100") }
    #expect(output.contains("40 100"))
    await session.terminate()
}

@Test func twoSessionsNeverCrossStreams() async throws {
    let sessionA = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-i"])
    let sessionB = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-i"])

    await sessionA.send(Data("echo MARKER-A\n".utf8))
    await sessionB.send(Data("echo MARKER-B\n".utf8))

    let outputA = await collectOutput(from: sessionA.output) { $0.contains("MARKER-A") }
    let outputB = await collectOutput(from: sessionB.output) { $0.contains("MARKER-B") }

    #expect(outputA.contains("MARKER-A"))
    #expect(!outputA.contains("MARKER-B"))
    #expect(outputB.contains("MARKER-B"))
    #expect(!outputB.contains("MARKER-A"))

    await sessionA.terminate()
    await sessionB.terminate()
}

@Test func cooperativeTerminateReapsChildAndClosesMasterFD() async throws {
    let session = try PTYExecSession(executablePath: "/bin/sh", arguments: ["-i"])
    let pid = await session.pidForTesting
    let masterFD = await session.masterFDForTesting

    await session.terminate()

    // Child reaped: signal 0 is the POSIX liveness probe (no signal sent);
    // ESRCH means the pid no longer exists.
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)

    // Master fd closed: `fcntl(fd, F_GETFD)` fails once the fd is closed.
    #expect(fcntl(masterFD, F_GETFD) == -1)

    // Stream finished — draining it should return immediately with nothing
    // further pending.
    var sawAnything = false
    for await _ in session.output { sawAnything = true }
    _ = sawAnything // finishing (not hanging) is the assertion; content is incidental.
}

@Test func terminateFallsBackToSIGKILLWhenGracePeriodExpires() async throws {
    // `trap "" INT` makes Ctrl-C a no-op for the foreground `sleep`, so the
    // cooperative path (Ctrl-C, then exit/EOF) cannot succeed — this forces
    // the short grace period to expire and exercises the SIGKILL fallback.
    //
    // `sleep 4` (not the brief's illustrative `sleep 30`): `sh -c 'trap ...;
    // sleep N'` forks `sleep` as a genuine grandchild here (no tail-call
    // exec optimization once a `trap` is set), so SIGKILLing the direct
    // child (the shell) orphans `sleep` for the remainder of its duration —
    // exactly S3's documented "SIGKILL fallback can orphan a process"
    // caveat, reproduced locally. `N` only needs to safely outlast
    // `terminateGrace` below; keeping it small bounds how long that orphan
    // (harmless, reaped by launchd) lingers in the test run.
    let session = try PTYExecSession(
        executablePath: "/bin/sh",
        arguments: ["-c", "trap '' INT; sleep 4"],
        terminateGrace: .milliseconds(300)
    )
    let pid = await session.pidForTesting

    await session.terminate()

    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}
