import Darwin
import Foundation

/// Which of the child process's two output streams carries the interesting
/// data for a given long-lived command (verified live probes): `logs`
/// streams **stdout** (finding #6); `image pull --progress plain` streams
/// **stderr** (finding #8).
enum StreamedFileDescriptor: Sendable {
    case stdout
    case stderr
    /// Route both descriptors into one pipe. This is the safe choice for a
    /// command such as `build` that can be chatty on either descriptor: no
    /// unread pipe can fill and deadlock the child.
    case combined
}

/// Turns a long-lived subprocess's line-oriented output into an
/// `AsyncThrowingStream`, applying the same SIGTERM→grace→SIGKILL
/// cancellation contract as `Subprocess.run` (plan spike S5) but for
/// children that outlive a single request/response call (`logs --follow`,
/// `image pull`, both unbounded until the consumer or the child exits).
///
/// **Exactly-once `finish()` discipline** (swift-concurrency-pro
/// `async-streams.md`/`bug-patterns.md`): only the reader `Task` below ever
/// calls `continuation.finish()`/`finish(throwing:)`. `continuation
/// .onTermination` — which fires on consumer cancellation *or* natural stream
/// deinit — only ever signals the child process; it never touches the
/// continuation. That split means a consumer-driven cancel and a natural EOF
/// can never race to double-finish: cancellation just makes the process die
/// sooner, and the reader task (still the only writer) observes that as an
/// ordinary EOF/exit-code transition and finishes once, as usual.
///
/// The escalation path only ever captures `pid: Int32` and a lock-guarded
/// exit coordinator (never the non-`Sendable` `Process`/`Pipe`/`FileHandle`).
/// Natural completion is delivered by `Process.terminationHandler`; the
/// reader retains the `Process` lifetime but awaits that coordinator instead
/// of calling Foundation's blocking `waitUntilExit()`, whose registration can
/// wedge after a very fast child has already exited under concurrent test
/// load.
///
/// **Caveat — sequential, not concurrent, fd draining:** the reader only
/// starts draining the *other* fd (for the failure-path stderr/stdout tail)
/// **after** the main fd reaches EOF, not concurrently with it (see the
/// implementation below). A pipe's kernel buffer is finite (64KB on Darwin);
/// if a child writes more than that to the *other* fd while the *main* fd is
/// still streaming, that write blocks the child once the buffer fills, and
/// since nothing here is reading the other fd yet, the child (and this
/// stream) stalls. Harmless for what P1A actually wraps — `logs` writes only
/// to stdout, `image pull --progress plain` writes only to stderr, so the
/// unread "other" fd only ever carries incidental noise, verified empty in
/// both live probes. This becomes a real risk if a later phase reuses this
/// type for something chattier on *both* fds. Such callers must choose
/// `.combined`, which routes both descriptors into the streamed pipe and
/// retains a bounded failure tail.
enum SubprocessLineStream {
    static func run<Element: Sendable>(
        executablePath: String,
        arguments: [String],
        commandDescription: String,
        readFrom: StreamedFileDescriptor,
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy,
        killEscalationGrace: Duration = .seconds(5),
        transform: @escaping @Sendable (String) -> Element
    ) throws -> AsyncThrowingStream<Element, Error> {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SubprocessError.executableNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let exitCoordinator = LineStreamExitCoordinator()
        process.terminationHandler = { finished in
            exitCoordinator.noteExit(finished.terminationStatus)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let readHandle: FileHandle
        let otherHandle: FileHandle?
        switch readFrom {
        case .stdout:
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            readHandle = stdoutPipe.fileHandleForReading
            otherHandle = stderrPipe.fileHandleForReading
        case .stderr:
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            readHandle = stderrPipe.fileHandleForReading
            otherHandle = stdoutPipe.fileHandleForReading
        case .combined:
            process.standardOutput = stdoutPipe
            process.standardError = stdoutPipe
            readHandle = stdoutPipe.fileHandleForReading
            otherHandle = nil
        }

        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                underlying: String(describing: error)
            )
        }

        let pid = process.processIdentifier
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )

        continuation.onTermination = { @Sendable termination in
            // `finish()` also invokes this callback. A naturally completed
            // stream has already observed the child's exit and must never
            // signal a possibly reused PID.
            guard case .cancelled = termination, !exitCoordinator.hasExited else { return }
            ProcessEscalation.terminateWithEscalation(
                processIdentifier: pid,
                terminate: { kill(pid, SIGTERM) },
                grace: killEscalationGrace,
                shouldEscalate: { !exitCoordinator.hasExited }
            )
        }

        Task {
            // The termination handler belongs to `process`; retain the
            // object until the reader has observed the stored exit result.
            // No Process API is called from this asynchronous task.
            defer { withExtendedLifetime(process) {} }
            var combinedTailLines: [String] = []
            do {
                for try await line in readHandle.bytes.lines {
                    if readFrom == .combined {
                        combinedTailLines.append(String(line.suffix(4_096)))
                        if combinedTailLines.count > 256 {
                            combinedTailLines.removeFirst(combinedTailLines.count - 256)
                        }
                    }
                    continuation.yield(transform(line))
                }
            } catch {
                // A forcefully-closed handle (the cancellation path, once
                // escalation kills the process) surfaces here as a read
                // error rather than clean EOF on some fd states — tolerate
                // it and fall through to the exit-code check below, which is
                // the authoritative source of truth for success/failure.
            }
            readHandle.closeFile()

            // Captured other-fd tail for error diagnostics: usually empty
            // (finding #8: pull's stdout is empty while it streams stderr),
            // but drained here in case the runtime ever writes anything
            // there on a failure path.
            var otherTail = ""
            if let otherHandle {
                do {
                    for try await line in otherHandle.bytes.lines {
                        otherTail += line + "\n"
                    }
                } catch {
                    // Best-effort tail capture only.
                }
                otherHandle.closeFile()
            }

            let exitCode = await exitCoordinator.waitForExit()
            if exitCode == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: RuntimeError.commandFailed(
                    command: commandDescription,
                    exitCode: exitCode,
                    stderr: (readFrom == .combined ? combinedTailLines.joined(separator: "\n") : otherTail)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        return stream
    }
}

/// Bridges `Process.terminationHandler` into async code without blocking a
/// cooperative executor thread. It deliberately supports exit-before-waiter
/// ordering because tiny scripted commands often finish before the stream
/// reader has drained both pipes.
final class LineStreamExitCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    var hasExited: Bool {
        lock.withLock { exitCode != nil }
    }

    func noteExit(_ code: Int32) {
        let waiter: CheckedContinuation<Int32, Never>? = lock.withLock {
            guard exitCode == nil else { return nil }
            exitCode = code
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(returning: code)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedCode: Int32? = lock.withLock {
                if let exitCode { return exitCode }
                self.continuation = continuation
                return nil
            }
            if let completedCode {
                continuation.resume(returning: completedCode)
            }
        }
    }
}
