import Foundation

/// MVP `ContainerRuntime` implementation: wraps the frozen public CLI as a
/// subprocess with `--format json` (plan §2.2). Every action stays reproducible
/// in a terminal. Post-MVP an XPCClient joins it behind the same protocol.
///
/// P1A Contract PR: signatures are frozen across the full protocol, but only
/// `cliVersion`, `listContainers`, `startContainer`, `stopContainer`,
/// `deleteContainer`, and `systemStatus` have real bodies. Everything else
/// throws `RuntimeError.notImplemented` until the P1A implementation PR lands.
public struct CLIProcessClient: ContainerRuntime {
    public let binaryPath: String

    public init(binaryPath: String? = nil) throws {
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
        throw RuntimeError.notImplemented(operation: "systemDiskUsage")
    }

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        var arguments = ["list"]
        if all { arguments.append("--all") }
        return try await invokeJSON(arguments)
    }

    /// `container inspect <id>` has no `--format` flag at all — passing one
    /// is a hard CLI usage error (exit 64). It always emits JSON
    /// unconditionally, unlike `list`/`stats`/`system status` (spike S2,
    /// finding #7). Never append `--format json` here when this lands.
    public func inspectContainer(id: String) async throws -> ContainerDetail {
        throw RuntimeError.notImplemented(operation: "inspectContainer")
    }

    public func createContainer(_ spec: RunSpec) async throws -> String {
        throw RuntimeError.notImplemented(operation: "createContainer")
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
        throw RuntimeError.notImplemented(operation: "killContainer")
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        var arguments = ["delete"]
        if force { arguments.append("--force") }
        arguments.append(id)
        try await invoke(arguments)
    }

    public func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        throw RuntimeError.notImplemented(operation: "logs")
    }

    public func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        throw RuntimeError.notImplemented(operation: "exec")
    }

    public func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        throw RuntimeError.notImplemented(operation: "stats")
    }

    public func listImages() async throws -> [ImageSummary] {
        throw RuntimeError.notImplemented(operation: "listImages")
    }

    public func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        throw RuntimeError.notImplemented(operation: "pullImage")
    }

    public func deleteImage(reference: String) async throws {
        throw RuntimeError.notImplemented(operation: "deleteImage")
    }

    public func tagImage(source: String, target: String) async throws {
        throw RuntimeError.notImplemented(operation: "tagImage")
    }

    public func listVolumes() async throws -> [VolumeSummary] {
        throw RuntimeError.notImplemented(operation: "listVolumes")
    }

    public func createVolume(name: String, labels: [String: String]) async throws {
        throw RuntimeError.notImplemented(operation: "createVolume")
    }

    public func deleteVolume(name: String) async throws {
        throw RuntimeError.notImplemented(operation: "deleteVolume")
    }

    public func listNetworks() async throws -> [NetworkSummary] {
        throw RuntimeError.notImplemented(operation: "listNetworks")
    }

    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        throw RuntimeError.notImplemented(operation: "createNetwork")
    }

    public func deleteNetwork(name: String) async throws {
        throw RuntimeError.notImplemented(operation: "deleteNetwork")
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
