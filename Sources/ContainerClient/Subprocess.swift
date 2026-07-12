import Foundation

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum SubprocessError: Error, Sendable {
    case executableNotFound(String)
    case launchFailed(command: String, underlying: String)
    case timedOut(command: String, after: Duration)
}

/// Runs external commands with argv arrays — never through a shell (plan §2.2).
/// Completion requires BOTH pipes to reach EOF AND the termination handler to
/// fire, so output is never truncated by the exit racing the reads.
public enum Subprocess {
    public static func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration = .seconds(60)
    ) async throws -> SubprocessResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SubprocessError.executableNotFound(executablePath)
        }
        let command = ([executablePath] + arguments).joined(separator: " ")

        let coordinator = RunCoordinator()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        attach(pipe: stdoutPipe, to: coordinator, stream: .stdout)
        attach(pipe: stderrPipe, to: coordinator, stream: .stderr)
        process.terminationHandler = { finished in
            coordinator.noteExit(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(command: command, underlying: String(describing: error))
        }

        let processBox = UncheckedSendableBox(process)
        return try await withThrowingTaskGroup(of: SubprocessResult?.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        coordinator.install(continuation)
                    }
                } onCancel: {
                    // TODO(M1): escalate SIGTERM → SIGKILL if the process
                    // ignores terminate() (matters for `build`, plan spike S5).
                    let process = processBox.value
                    if process.isRunning { process.terminate() }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                if let result = outcome { return result }
                throw SubprocessError.timedOut(command: command, after: timeout)
            }
            throw CancellationError()
        }
    }

    fileprivate enum StreamID { case stdout, stderr }

    private static func attach(pipe: Pipe, to coordinator: RunCoordinator, stream: StreamID) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                coordinator.noteEOF()
            } else {
                coordinator.append(chunk, to: stream)
            }
        }
    }
}

/// Lock-guarded rendezvous of the three completion signals (stdout EOF, stderr
/// EOF, termination). Resumes the continuation exactly once.
private final class RunCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var openStreams = 2
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<SubprocessResult, Never>?

    func append(_ data: Data, to stream: Subprocess.StreamID) {
        lock.withLock {
            switch stream {
            case .stdout: stdout.append(data)
            case .stderr: stderr.append(data)
            }
        }
    }

    func noteEOF() {
        resumeIfFinished { self.openStreams -= 1 }
    }

    func noteExit(_ code: Int32) {
        resumeIfFinished { self.exitCode = code }
    }

    func install(_ continuation: CheckedContinuation<SubprocessResult, Never>) {
        resumeIfFinished { self.continuation = continuation }
    }

    private func resumeIfFinished(_ mutate: () -> Void) {
        let ready: (CheckedContinuation<SubprocessResult, Never>, SubprocessResult)? = lock.withLock {
            mutate()
            guard openStreams == 0, let exitCode, let continuation else { return nil }
            self.continuation = nil
            return (continuation, SubprocessResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
        }
        if let (continuation, result) = ready {
            continuation.resume(returning: result)
        }
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
