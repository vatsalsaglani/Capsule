import Foundation

/// MVP `ContainerRuntime` implementation: wraps the frozen public CLI as a
/// subprocess with `--format json` (plan §2.2). Every action stays reproducible
/// in a terminal. Post-MVP an XPCClient joins it behind the same protocol.
///
/// P1A implementation PR: every method beyond the Contract PR's original six
/// (`cliVersion`, `listContainers`, `startContainer`, `stopContainer`,
/// `deleteContainer`, `systemStatus`) now has a real body, built against live
/// probes of `container` 1.1.0 (see `docs/learnings/
/// 2026-07-12-runtime-cli-observations.md` and the P1A implementation note).
public struct CLIProcessClient: ContainerRuntime {
    public let binaryPath: String
    /// Poll cadence for the `stats` one-shot loop (`container stats
    /// --no-stream --format json`, spike S2 finding #9 — real streaming mode
    /// emits exactly one array and then goes silent, so `stats` cannot be a
    /// genuine long-lived stream; this polls instead).
    public let statsInterval: Duration

    public init(binaryPath: String? = nil, statsInterval: Duration = .seconds(2)) throws {
        self.statsInterval = statsInterval
        if let binaryPath {
            self.binaryPath = binaryPath
            return
        }
        guard let located = ContainerBinaryLocator.locate() else {
            throw RuntimeError.binaryNotFound(searched: [
                "$\(ContainerBinaryLocator.environmentOverrideKey)",
                ContainerBinaryLocator.defaultInstallPath,
                "$PATH",
            ])
        }
        self.binaryPath = located
    }

    public func cliVersion() async throws -> SemanticVersion {
        let result = try await invoke(["--version"], timeout: .seconds(10))
        guard let version = SemanticVersion(firstIn: result.stdoutText) else {
            throw RuntimeError.decodingFailed(
                command: "container --version",
                detail: "no x.y.z version in: \(result.stdoutText)"
            )
        }
        return version
    }

    public func systemStatus() async throws -> SystemStatus {
        try await invokeJSON(["system", "status"], timeout: .seconds(10))
    }

    public func systemDiskUsage() async throws -> SystemDiskUsage {
        try await invokeJSON(["system", "df"])
    }

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        var arguments = ["list"]
        if all { arguments.append("--all") }
        return try await invokeJSON(arguments)
    }

    /// `container inspect <id>` has no `--format` flag at all — passing one
    /// is a hard CLI usage error (exit 64). It always emits JSON
    /// unconditionally, unlike `list`/`stats`/`system status` (spike S2,
    /// finding #7). Never append `--format json` here.
    public func inspectContainer(id: String) async throws -> ContainerDetail {
        let command = "container inspect \(id)"
        let result = try await invoke(["inspect", id])
        do {
            let details = try RuntimeJSON.makeDecoder().decode([ContainerDetail].self, from: result.stdout)
            guard let detail = details.first else {
                throw RuntimeError.decodingFailed(command: command, detail: "empty array in response")
            }
            return detail
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.decodingFailed(command: command, detail: String(describing: error))
        }
    }

    /// `container create` (never `run` — see `RunSpec`'s doc comment).
    /// Verified live: the container id is printed alone on stdout, with
    /// `[n/6] …` progress noise on stderr — take the last non-empty stdout
    /// line as the id and ignore stderr entirely on a zero exit.
    public func createContainer(_ spec: RunSpec) async throws -> String {
        let result = try await invoke(["create"] + spec.createArguments)
        let lastNonEmptyLine = result.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let id = lastNonEmptyLine else {
            throw RuntimeError.decodingFailed(
                command: "container create",
                detail: "no id on stdout: \(result.stdoutText)"
            )
        }
        return id
    }

    public func startContainer(id: String) async throws {
        try await invoke(["start", id])
    }

    public func stopContainer(id: String, timeoutSeconds: Int?) async throws {
        var arguments = ["stop"]
        if let timeoutSeconds {
            arguments.append(contentsOf: ["-t", String(timeoutSeconds)])
        }
        arguments.append(id)
        try await invoke(arguments)
    }

    public func killContainer(id: String, signal: String) async throws {
        try await invoke(["kill", "--signal", signal, id])
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        var arguments = ["delete"]
        if force { arguments.append("--force") }
        arguments.append(id)
        try await invoke(arguments)
    }

    /// `logs` emits to stdout, plain `\n`-terminated lines (spike finding
    /// #6) — streamed via `SubprocessLineStream` with the same
    /// SIGTERM→grace→SIGKILL cancellation contract as every other
    /// `Subprocess`-spawned child.
    public func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        var arguments = ["logs"]
        if follow { arguments.append("--follow") }
        if let tail { arguments.append(contentsOf: ["-n", String(tail)]) }
        arguments.append(id)
        return try SubprocessLineStream.run(
            executablePath: binaryPath,
            arguments: arguments,
            commandDescription: "container " + arguments.joined(separator: " "),
            readFrom: .stdout,
            bufferingPolicy: .bufferingNewest(4096),
            transform: { LogLine(text: $0) }
        )
    }

    /// `exec` propagates the inner command's exit code exactly (verified
    /// live: `sh -c 'exit 7'` → CLI exit 7) — a non-zero exit is a
    /// legitimate `ExecResult`, not a thrown error, so this bypasses
    /// `invoke`'s exit-code guard and calls `Subprocess.run` directly. Only
    /// spawn/timeout failures throw. Honest ambiguity: "container not found"
    /// also surfaces as a non-zero `ExecResult` with a stderr message rather
    /// than a typed error — P3's health-probe design already treats any
    /// non-zero exit as "unhealthy," so this is the correct behavior for
    /// that consumer, not a gap.
    public func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        let result = try await Subprocess.run(
            executablePath: binaryPath,
            arguments: ["exec", id] + argv,
            timeout: timeout
        )
        return ExecResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    /// `container stats --format json` in streaming mode emits exactly one
    /// JSON array and then goes silent forever (spike S2 finding #9,
    /// corrected — the original note's "one array per tick" streaming claim
    /// was wrong; see the learnings note). Implemented as a poll loop over
    /// `container stats --no-stream --format json [ids…]` instead: one
    /// one-shot `Subprocess.run` per tick, decode, yield, sleep
    /// `statsInterval`, repeat until the consumer cancels.
    public func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        let binaryPath = self.binaryPath
        let interval = statsInterval
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: [StatsSample].self,
            bufferingPolicy: .bufferingNewest(16)
        )

        let pollTask = Task {
            while true {
                let arguments = ["stats", "--no-stream", "--format", "json"] + ids
                do {
                    let result = try await Subprocess.run(
                        executablePath: binaryPath,
                        arguments: arguments,
                        timeout: .seconds(10)
                    )
                    guard result.exitCode == 0 else {
                        continuation.finish(throwing: RuntimeError.commandFailed(
                            command: "container " + arguments.joined(separator: " "),
                            exitCode: result.exitCode,
                            stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        return
                    }
                    let samples = try RuntimeJSON.makeDecoder().decode([StatsSample].self, from: result.stdout)
                    continuation.yield(samples)
                } catch is CancellationError {
                    return
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
        // Consumer walked away: cancel the poll loop. No explicit `finish()`
        // here — cancellation is observed by the loop itself (via
        // `Task.isCancelled`/the sleep throwing), keeping `finish` the sole
        // responsibility of the polling task, matching `SubprocessLineStream`'s
        // exactly-once discipline.
        continuation.onTermination = { _ in pollTask.cancel() }
        return stream
    }

    public func listImages() async throws -> [ImageSummary] {
        try await invokeJSON(["image", "list"])
    }

    /// `image pull --progress plain` streams progress lines on **stderr**;
    /// stdout is empty (spike finding #8).
    public func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        var arguments = ["image", "pull", "--progress", "plain"]
        if let platform { arguments.append(contentsOf: ["--platform", platform]) }
        arguments.append(reference)
        return try SubprocessLineStream.run(
            executablePath: binaryPath,
            arguments: arguments,
            commandDescription: "container " + arguments.joined(separator: " "),
            readFrom: .stderr,
            bufferingPolicy: .bufferingNewest(256),
            transform: { PullProgress(message: $0) }
        )
    }

    public func deleteImage(reference: String) async throws {
        try await invoke(["image", "delete", reference])
    }

    public func tagImage(source: String, target: String) async throws {
        try await invoke(["image", "tag", source, target])
    }

    public func listVolumes() async throws -> [VolumeSummary] {
        try await invokeJSON(["volume", "ls"])
    }

    public func createVolume(name: String, labels: [String: String]) async throws {
        var arguments = ["volume", "create"]
        arguments.append(contentsOf: labelArguments(labels))
        arguments.append(name)
        try await invoke(arguments)
    }

    public func deleteVolume(name: String) async throws {
        try await invoke(["volume", "delete", name])
    }

    public func listNetworks() async throws -> [NetworkSummary] {
        try await invokeJSON(["network", "ls"])
    }

    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        var arguments = ["network", "create"]
        arguments.append(contentsOf: labelArguments(labels))
        if isInternal { arguments.append("--internal") }
        arguments.append(name)
        try await invoke(arguments)
    }

    public func deleteNetwork(name: String) async throws {
        try await invoke(["network", "delete", name])
    }

    /// `--label k=v`, one per entry, sorted by key — same determinism
    /// discipline as `RunSpec.createArguments`.
    private func labelArguments(_ labels: [String: String]) -> [String] {
        labels.sorted { $0.key < $1.key }.flatMap { ["--label", "\($0.key)=\($0.value)"] }
    }

    @discardableResult
    private func invoke(
        _ arguments: [String],
        timeout: Duration = .seconds(60)
    ) async throws -> SubprocessResult {
        let result = try await Subprocess.run(
            executablePath: binaryPath,
            arguments: arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw RuntimeError.commandFailed(
                command: "container " + arguments.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func invokeJSON<T: Decodable & Sendable>(
        _ arguments: [String],
        timeout: Duration = .seconds(60)
    ) async throws -> T {
        let command = "container " + arguments.joined(separator: " ") + " --format json"
        let result = try await invoke(arguments + ["--format", "json"], timeout: timeout)
        do {
            return try RuntimeJSON.makeDecoder().decode(T.self, from: result.stdout)
        } catch {
            throw RuntimeError.decodingFailed(command: command, detail: String(describing: error))
        }
    }
}
