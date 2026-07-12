import Foundation

/// Runtime access protocol (plan §2.2). Both frontends and the compose engine
/// talk to Apple's `container` runtime exclusively through this protocol so the
/// CLI-subprocess implementation can be swapped for an XPC client post-MVP.
///
/// Surface is frozen by the P1A Contract PR (`design-an-interface` skill run
/// against this exact shape) — containers, images, volumes, networks, and
/// system surfaces all land here at once so downstream consumers (ComposeRuntime,
/// Supervisor, App) can build against the full shape before `CLIProcessClient`
/// grows real bodies. Deliberately excluded from this surface: `events()`
/// (P1A step 2, Poller→EventBus), restart policy on `RunSpec` (Supervisor's
/// job), interactive/PTY exec (P1C), `build`, and prune methods.
public protocol ContainerRuntime: Sendable {
    // MARK: System

    /// Backing command: `container --version`.
    func cliVersion() async throws -> SemanticVersion

    /// Backing command: `container system status --format json` (plan §2.2).
    func systemStatus() async throws -> SystemStatus

    /// Backing command: `container system df --format json`.
    func systemDiskUsage() async throws -> SystemDiskUsage

    // MARK: Containers

    /// Backing command: `container list [--all] --format json`.
    func listContainers(all: Bool) async throws -> [ContainerSummary]

    /// Backing command: `container inspect <id>`. Never append `--format
    /// json` — `inspect` has no `--format` flag and errors (exit 64) if
    /// passed one; it always emits JSON unconditionally (spike S2, finding #7).
    func inspectContainer(id: String) async throws -> ContainerDetail

    /// Backing command: `container run …` built from the `RunSpec` argv
    /// mapping table (plan §4.3). Returns the created container id.
    func createContainer(_ spec: RunSpec) async throws -> String

    /// Backing command: `container start <id>`.
    func startContainer(id: String) async throws

    /// Backing command: `container stop [-t <seconds>] <id>`.
    func stopContainer(id: String, timeoutSeconds: Int?) async throws

    /// Backing command: `container kill --signal <signal> <id>`.
    func killContainer(id: String, signal: String) async throws

    /// Backing command: `container delete [--force] <id>`.
    func deleteContainer(id: String, force: Bool) async throws

    /// Backing command: `container logs [--follow] [-n <tail>] <id>`.
    func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error>

    /// Backing command: `container exec <id> -- <argv>` (non-interactive;
    /// plan §4.6 health probes depend on this). Interactive/PTY exec is P1C.
    func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult

    /// Backing command: `container stats --format json [ids...]`. One stream
    /// element per tick; an empty `ids` array means "all containers".
    func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error>

    // MARK: Images

    /// Backing command: `container image list --format json`.
    func listImages() async throws -> [ImageSummary]

    /// Backing command: `container image pull [--platform <platform>] <reference>`.
    func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error>

    /// Backing command: `container image delete <reference>`.
    func deleteImage(reference: String) async throws

    /// Backing command: `container image tag <source> <target>`.
    func tagImage(source: String, target: String) async throws

    // MARK: Volumes

    /// Backing command: `container volume ls --format json`.
    func listVolumes() async throws -> [VolumeSummary]

    /// Backing command: `container volume create [--label k=v ...] <name>`.
    func createVolume(name: String, labels: [String: String]) async throws

    /// Backing command: `container volume delete <name>`.
    func deleteVolume(name: String) async throws

    // MARK: Networks

    /// Backing command: `container network ls --format json`.
    func listNetworks() async throws -> [NetworkSummary]

    /// Backing command: `container network create [--label k=v ...] [--internal] <name>`.
    func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws

    /// Backing command: `container network delete <name>`.
    func deleteNetwork(name: String) async throws
}

extension ContainerRuntime {
    /// Source-compat shim for pre-contract call sites (App ContainersView).
    public func stopContainer(id: String) async throws { try await stopContainer(id: id, timeoutSeconds: nil) }
}

public enum RuntimeError: Error, Sendable {
    case binaryNotFound(searched: [String])
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(command: String, detail: String)
    case notImplemented(operation: String)
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
        case .notImplemented(let operation):
            return "`\(operation)` is not implemented yet (P1A signature freeze; body lands in the implementation PR)"
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
