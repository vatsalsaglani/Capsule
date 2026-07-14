import Darwin
import Foundation

/// `TerminalSession` over a raw PTY (S3 decision — not SwiftTerm's
/// `LocalProcess`). Spawns a child (in production, `container exec -it <id>
/// <shell>`) under a `forkpty()`-allocated PTY (`PTY.swift`) and bridges
/// bytes both ways.
///
/// **Cross-context values are `Int32`s only.** There is no `Process` object
/// here (unlike `Subprocess.swift`, which wraps `Foundation.Process` and
/// needs `UncheckedSendableBox` to smuggle it into a detached task) — `fork`
/// gives us a bare `childPID`, and the PTY gives us a bare `masterFD`. Both
/// are `Sendable` value types, so nothing in this file needs `@unchecked
/// Sendable`.
///
/// **State machine + exactly-once teardown:** `state` only ever moves
/// forward `running` → `terminating` → `exited`. `finish(exitCode:)` is the
/// single idempotent teardown (closes the master fd, finishes `output`,
/// resumes every `waitUntilExit()` waiter) — both the EOF-driven reap
/// (`handleChildExit`) and `terminate()`'s own completion check fall through
/// `reapIfNeeded()`, which is itself guarded (`reapAttempted`) so exactly one
/// `waitpid` loop ever runs per spawn, however many routes ask for it.
///
/// **Reader vs. actor split (why `output` never races `terminate()`):** the
/// `FileHandle.readabilityHandler` closure below yields bytes directly on
/// `continuation` — `AsyncStream.Continuation.yield` is `Sendable`/thread
/// safe, so this never needs to hop onto the actor. Only the *state
/// transition* (EOF → "the child is gone, reap it") hops into the actor via
/// `Task { await self.handleChildExit() }`. That split means production of
/// `output` bytes and the actor's terminate/finish bookkeeping are two
/// disjoint concerns that can never interleave into a corrupt state: the
/// reader only ever yields or triggers the actor-serialized reap, never
/// mutates actor state directly.
public actor PTYExecSession: TerminalSession {
    enum State: Sendable {
        case running
        case terminating
        case exited(code: Int32?)
    }

    public nonisolated let output: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let masterFD: Int32
    private let childPID: Int32
    private let terminateGrace: Duration

    private var fileHandle: FileHandle?
    private var state: State = .running
    private var reapAttempted = false
    private var childWasReaped = false
    private var masterFDCloseResult: Int32?
    private var exitWaiters: [CheckedContinuation<Int32?, Never>] = []
    /// See `waitForGracefulExit`'s doc comment for why this exists instead
    /// of a `TaskGroup`-based race.
    private var graceContinuation: CheckedContinuation<Bool, Never>?

    /// Generalized for testability (brief): tests drive local `/bin/sh`
    /// directly; `makeContainerExecFactory` below is the production
    /// convenience that builds the `container exec -it` argv.
    public init(
        executablePath: String,
        arguments: [String],
        initialColumns: Int = 80,
        initialRows: Int = 24,
        terminateGrace: Duration = .seconds(2)
    ) throws {
        let (masterFD, childPID) = try PTY.spawn(
            executablePath: executablePath,
            arguments: arguments,
            columns: initialColumns,
            rows: initialRows
        )
        self.masterFD = masterFD
        self.childPID = childPID
        self.terminateGrace = terminateGrace

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self,
            // DELIBERATE exception to the bounded-buffer default (contrast
            // `SubprocessLineStream`'s `.bufferingNewest(4096)`): dropping
            // *any* byte here can corrupt SwiftTerm's escape-sequence state
            // machine mid multi-byte sequence — a truncated `\x1b[...m`
            // renders as garbage, not just a missed update. The sole
            // consumer is one UI view draining at terminal-render speed
            // (human typing / a foreground program's own output rate), not
            // a high-throughput producer in the sense the bounded-buffer
            // rule guards against.
            bufferingPolicy: .unbounded
        )
        self.output = stream
        self.continuation = continuation

        let handle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        self.fileHandle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: the child's PTY slave closed (clean exit, our own
                // cooperative-terminate sequence, or the container itself
                // going away out from under an attached session — S3, exit
                // 137). Never a blocking read/waitpid on the cooperative
                // pool: this closure only yields/hops, the actual reap
                // happens inside the actor via a WNOHANG poll loop.
                handle.readabilityHandler = nil
                Task { await self?.handleChildExit() }
            } else {
                continuation.yield(data)
            }
        }
    }

    /// Production factory: `container exec -it -e TERM=xterm-256color <id>
    /// <shell>` (brief's argv, S3-grounded — `-i`+`-t` both required for TTY
    /// allocation; live-verified TERM propagation, see learnings note).
    public static func makeContainerExecFactory(
        binaryPath: String,
        terminateGrace: Duration = .seconds(2)
    ) -> @Sendable (_ containerID: String, _ shell: String) throws -> any TerminalSession {
        { containerID, shell in
            try PTYExecSession(
                executablePath: binaryPath,
                arguments: ["exec", "-it", "-e", "TERM=xterm-256color", containerID, shell],
                terminateGrace: terminateGrace
            )
        }
    }

    public func send(_ data: Data) async {
        // Post-terminate `send` is a no-op — only `terminate()`'s own
        // cooperative-shutdown bytes are allowed to reach the master fd
        // once teardown has begun.
        guard case .running = state else { return }
        writeBytes(data)
    }

    public func resize(columns: Int, rows: Int) async {
        guard case .running = state else { return }
        PTY.resize(masterFD: masterFD, columns: columns, rows: rows)
    }

    /// Cooperative terminate (S3 MAJOR finding: SIGTERM/SIGINT are no-ops
    /// against the local `container exec -it` client — shutdown must happen
    /// over the PTY byte stream). Idempotent: a second concurrent/late call
    /// while already `.terminating`/`.exited` is a no-op, so `output`
    /// production is never raced by two overlapping teardown sequences.
    public func terminate() async {
        switch state {
        case .exited, .terminating:
            return
        case .running:
            state = .terminating
        }

        writeBytes(Data([0x03])) // Ctrl-C: interrupt any foreground command.
        try? await Task.sleep(for: .milliseconds(120))
        writeBytes(Data("exit\n".utf8)) // End the shell cleanly...
        writeBytes(Data([0x04])) // ...and EOF in case `exit` alone doesn't.

        if await waitForGracefulExit(timeout: terminateGrace) {
            return
        }

        // Fallback: SIGKILL the LOCAL `container exec -it` client only. Per
        // S3's MAJOR finding this can orphan a process *inside* a
        // still-running container (the exec client's own teardown doesn't
        // propagate into the container) — an accepted, narrow gap that only
        // bites "force-close a tab mid hung foreground command"; see
        // docs/spikes/S3-pty-exec.md.
        if kill(childPID, 0) == 0 {
            kill(childPID, SIGKILL)
        }
        _ = await reapIfNeeded()
    }

    public func waitUntilExit() async -> Int32? {
        if case .exited(let code) = state { return code }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            exitWaiters.append(continuation)
        }
    }

    // MARK: - Test-only accessors
    //
    // Internal (not `public`), reachable only via `@testable import
    // TerminalKit` from `Tests/TerminalKitTests` — not part of the public
    // API surface. Needed to assert directly on OS-level teardown (`kill(pid,
    // 0)` → ESRCH, `fcntl(fd, F_GETFD)` → closed) rather than only
    // black-box behavior.

    var pidForTesting: Int32 { childPID }
    var childWasReapedForTesting: Bool { childWasReaped }
    var masterFDCloseSucceededForTesting: Bool { masterFDCloseResult == 0 }

    // MARK: - Private

    private func handleChildExit() async {
        _ = await reapIfNeeded()
    }

    /// The single reap+finish path, however many routes call it (EOF, or
    /// `terminate()`'s SIGKILL fallback). `reapAttempted` guards against a
    /// second `waitpid` loop starting concurrently — a late caller just
    /// awaits the in-flight (or already-finished) result instead.
    private func reapIfNeeded() async -> Int32? {
        if case .exited(let code) = state { return code }
        if reapAttempted {
            return await waitUntilExit()
        }
        reapAttempted = true

        var status: Int32 = 0
        var reapedCode: Int32?
        // WNOHANG poll with short sleeps — never a blocking `waitpid` on the
        // cooperative pool. ~80 * 25ms = 2s budget, generous relative to
        // `terminateGrace`'s own race in `waitForGracefulExit`.
        for _ in 0..<80 {
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID {
                childWasReaped = true
                reapedCode = Self.exitCode(fromStatus: status)
                break
            }
            if result == -1 && errno == ECHILD {
                // No waitable child remains. This is equivalent to a
                // completed reap for teardown purposes.
                childWasReaped = true
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        finish(exitCode: reapedCode)
        return reapedCode
    }

    /// Races `waitUntilExit()` against `timeout`; used by `terminate()` to
    /// decide whether the cooperative PTY-byte shutdown worked before
    /// escalating to SIGKILL.
    ///
    /// **Deliberately not a `TaskGroup`-based race.** `withTaskGroup` (and
    /// `withThrowingTaskGroup`) waits for *every* child task to finish
    /// before the enclosing call returns, even after `cancelAll()` —
    /// cancellation is cooperative, and a child task suspended on a
    /// `CheckedContinuation` (as `waitUntilExit()`'s waiters are) has no way
    /// to observe cancellation and resume early. Racing `waitUntilExit()`
    /// against a timeout inside a `TaskGroup` therefore doesn't return in
    /// `timeout` when the timeout wins — it silently blocks until the real
    /// exit eventually happens (verified: an early build of this function
    /// took the full duration of a 30s test fixture to return instead of a
    /// 300ms `terminateGrace`). Instead, this registers a dedicated,
    /// actor-owned continuation (`graceContinuation`) that either the
    /// timeout `Task` below or `finish()` resumes — exactly once, guarded by
    /// `resolveGraceContinuation` clearing the field before resuming. The
    /// timeout `Task` is deliberately unstructured (plain `Task {}`, not a
    /// `TaskGroup` child) specifically so this function is never on the
    /// hook to await its completion — whichever side resumes first wins,
    /// and the loser's later no-op call to `resolveGraceContinuation` is
    /// harmless.
    private func waitForGracefulExit(timeout: Duration) async -> Bool {
        if case .exited = state { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            graceContinuation = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.resolveGraceContinuation(exited: false)
            }
        }
    }

    /// Resumes the pending `waitForGracefulExit` continuation exactly once
    /// (guarded by clearing `graceContinuation` before resuming) — called by
    /// both the timeout `Task` (`exited: false`) and `finish()` (`exited:
    /// true`, for every still-pending waiter, i.e. at most one today).
    private func resolveGraceContinuation(exited: Bool) {
        guard let continuation = graceContinuation else { return }
        graceContinuation = nil
        continuation.resume(returning: exited)
    }

    /// The one idempotent teardown. Guarded by `state`: a second call (from
    /// whichever of `reapIfNeeded`'s callers loses the race) is a no-op.
    private func finish(exitCode: Int32?) {
        guard case .exited = state else {
            state = .exited(code: exitCode)
            fileHandle?.readabilityHandler = nil
            fileHandle = nil
            masterFDCloseResult = close(masterFD)
            continuation.finish()
            let waiters = exitWaiters
            exitWaiters = []
            for waiter in waiters {
                waiter.resume(returning: exitCode)
            }
            resolveGraceContinuation(exited: true)
            return
        }
    }

    private func writeBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(masterFD, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    break // fd likely closed/gone — nothing more to do.
                }
            }
        }
    }

    private static func exitCode(fromStatus status: Int32) -> Int32 {
        let exitedNormally = (status & 0x7f) == 0
        if exitedNormally {
            return (status >> 8) & 0xff
        }
        // Signaled — 128+signal, matching conventional shell/CLI exit-code
        // reporting (also how `container` itself reports the "killed" case,
        // e.g. exit 137 = 128+SIGKILL, per S3).
        let signal = status & 0x7f
        return 128 + signal
    }

    deinit {
        // Safety net only: normal teardown always goes through `finish`.
        // Actor `deinit` runs with no other reference alive, so touching
        // stored state directly here is safe (no concurrent access
        // possible) — this just avoids leaking the master fd if a session
        // is ever dropped without `terminate()` being called.
        fileHandle?.readabilityHandler = nil
        if masterFDCloseResult == nil {
            close(masterFD)
        }
    }
}
