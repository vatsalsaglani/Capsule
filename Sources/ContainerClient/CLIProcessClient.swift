import Foundation

/// MVP `ContainerRuntime` implementation: wraps the frozen public CLI as a
/// subprocess with `--format json` (plan §2.2). Every action stays reproducible
/// in a terminal. Post-MVP an XPCClient joins it behind the same protocol.
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

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        var arguments = ["list"]
        if all { arguments.append("--all") }
        return try await invokeJSON(arguments)
    }

    public func startContainer(id: String) async throws {
        try await invoke(["start", id])
    }

    public func stopContainer(id: String) async throws {
        try await invoke(["stop", id])
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        var arguments = ["delete"]
        if force { arguments.append("--force") }
        arguments.append(id)
        try await invoke(arguments)
    }

    /// Raw `container system status` output for doctor/onboarding surfaces.
    public func systemStatus() async throws -> String {
        try await invoke(["system", "status"], timeout: .seconds(10)).stdoutText
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

    private func invokeJSON<T: Decodable & Sendable>(_ arguments: [String]) async throws -> T {
        let command = "container " + arguments.joined(separator: " ") + " --format json"
        let result = try await invoke(arguments + ["--format", "json"])
        do {
            return try JSONDecoder().decode(T.self, from: result.stdout)
        } catch {
            throw RuntimeError.decodingFailed(command: command, detail: String(describing: error))
        }
    }
}
