import Darwin
import Foundation

/// Which of the child process's two output streams carries the interesting
/// data for a given long-lived command (verified live probes): `logs`
/// streams **stdout** (finding #6); `image pull --progress plain` streams
/// **stderr** (finding #8).
enum StreamedFileDescriptor: Sendable {
    case stdout
    case stderr
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
/// The escalation path only ever captures `pid: Int32` (never the
/// non-`Sendable` `Process`/`Pipe`/`FileHandle`) — `onTermination` sends
/// `kill(pid, SIGTERM)` directly rather than calling `process.terminate()`,
/// so nothing here needs to touch the `Process` object from outside the
/// single reader `Task` that owns it, and no `@unchecked Sendable` wrapper is
/// needed (contrast `Subprocess.swift`'s `UncheckedSendableBox`, which stays
/// scoped to that file only).
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let readHandle = (readFrom == .stdout ? stdoutPipe : stderrPipe).fileHandleForReading
        let otherHandle = (readFrom == .stdout ? stderrPipe : stdoutPipe).fileHandleForReading

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

        continuation.onTermination = { @Sendable _ in
            ProcessEscalation.terminateWithEscalation(
                processIdentifier: pid,
                terminate: { kill(pid, SIGTERM) },
                grace: killEscalationGrace
            )
        }

        Task {
            do {
                for try await line in readHandle.bytes.lines {
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
            do {
                for try await line in otherHandle.bytes.lines {
                    otherTail += line + "\n"
                }
            } catch {
                // Best-effort tail capture only.
            }
            otherHandle.closeFile()

            process.waitUntilExit()
            let exitCode = process.terminationStatus
            if exitCode == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: RuntimeError.commandFailed(
                    command: commandDescription,
                    exitCode: exitCode,
                    stderr: otherTail.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        return stream
    }
}
