import Foundation

/// Runtime access protocol (plan §2.2). Both frontends and the compose engine
/// talk to Apple's `container` runtime exclusively through this protocol so the
/// CLI-subprocess implementation can be swapped for an XPC client post-MVP.
///
/// Surface grows milestone by milestone — logs, stats, exec, events, images,
/// volumes, networks, and build land per docs/ROADMAP.md. Run the
/// design-an-interface skill before widening it.
public protocol ContainerRuntime: Sendable {
    func cliVersion() async throws -> SemanticVersion
    func listContainers(all: Bool) async throws -> [ContainerSummary]
    func startContainer(id: String) async throws
    func stopContainer(id: String) async throws
    func deleteContainer(id: String, force: Bool) async throws
}

public enum RuntimeError: Error, Sendable {
    case binaryNotFound(searched: [String])
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(command: String, detail: String)
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            return "container CLI not found (searched: \(searched.joined(separator: ", ")))"
        case .commandFailed(let command, let exitCode, let stderr):
            let detail = stderr.isEmpty ? "no stderr output" : stderr
            return "`\(command)` exited with status \(exitCode): \(detail)"
        case .decodingFailed(let command, let detail):
            return "could not decode output of `\(command)`: \(detail)"
        }
    }
}

/// Finds the `container` binary. Order: explicit override env var, the default
/// install location, then $PATH.
public enum ContainerBinaryLocator {
    public static let environmentOverrideKey = "CAPSULE_CONTAINER_BIN"
    public static let defaultInstallPath = "/usr/local/bin/container"

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return override
        }
        if FileManager.default.isExecutableFile(atPath: defaultInstallPath) {
            return defaultInstallPath
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/container"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
