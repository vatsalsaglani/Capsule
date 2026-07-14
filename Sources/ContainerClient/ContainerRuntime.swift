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
/// job), and interactive/PTY exec (P1C).
public protocol ContainerRuntime: Sendable {
    // MARK: System

    /// Backing command: `container --version`.
    func cliVersion() async throws -> SemanticVersion

    /// Backing command: `container system status --format json` (plan §2.2).
    func systemStatus() async throws -> SystemStatus

    /// Backing command: `container system df --format json`.
    func systemDiskUsage() async throws -> SystemDiskUsage

    /// Backing command: `container system start`. System-wide (not scoped to
    /// a resource id), so `RuntimeGateway` treats this as pass-through rather
    /// than serialized (P1B B0 addendum).
    func systemStart() async throws

    /// Backing command: `container system stop`. System-wide, pass-through
    /// (P1B B0 addendum).
    func systemStop() async throws

    // MARK: Containers

    /// Backing command: `container list [--all] --format json`.
    func listContainers(all: Bool) async throws -> [ContainerSummary]

    /// Backing command: `container inspect <id>`. Never append `--format
    /// json` — `inspect` has no `--format` flag and errors (exit 64) if
    /// passed one; it always emits JSON unconditionally (spike S2, finding #7).
    func inspectContainer(id: String) async throws -> ContainerDetail

    /// Backing command: `container create` (not `run` — `run` is
    /// create+start, and this method must not start the container as a side
    /// effect, or it breaks the planner's `EnsureContainer`→`Start`
    /// separation and `depends_on` ordering, plan §4.5) built from the
    /// `RunSpec` argv mapping table (plan §4.3). Returns the created
    /// container id.
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

    /// Backing command: `container exec <id> <argv>` (non-interactive;
    /// plan §4.6 health probes depend on this). Interactive/PTY exec is P1C.
    func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult

    /// Process-level identity override for a non-interactive exec. Options
    /// precede the container ID in the CLI implementation. The default
    /// witness below preserves older conformers but never silently drops a
    /// non-default user request.
    func exec(
        id: String,
        argv: [String],
        options: ExecOptions,
        timeout: Duration
    ) async throws -> ExecResult

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

    /// Backing command: `container build --progress plain ...`. Build output
    /// is a concrete stream for the same future-XPC compatibility reason as
    /// logs, stats, and pulls.
    func buildImage(_ spec: ImageBuildSpec) async throws -> AsyncThrowingStream<BuildProgress, Error>

    // MARK: Builder

    /// Backing command: `container builder status --format json`.
    func builderStatus() async throws -> BuilderStatus

    /// Backing command: `container builder start`.
    func startBuilder(_ configuration: BuilderConfiguration) async throws

    /// Backing command: `container builder stop`.
    func stopBuilder() async throws

    /// Backing command: `container builder delete [--force]`.
    func deleteBuilder(force: Bool) async throws

    // MARK: Volumes

    /// Backing command: `container volume ls --format json`.
    func listVolumes() async throws -> [VolumeSummary]

    /// Backing command: `container volume create [--label k=v ...]
    /// [-s bytes] <name>`.
    func createVolume(_ spec: VolumeCreateSpec) async throws

    /// P1 source-compatible requirement. New consumers should prefer the
    /// spec overload above.
    func createVolume(name: String, labels: [String: String]) async throws

    /// Backing command: `container volume delete <name>`.
    func deleteVolume(name: String) async throws

    /// Backing command: `container volume prune`.
    func pruneVolumes() async throws -> PruneReport

    // MARK: Networks

    /// Backing command: `container network ls --format json`.
    func listNetworks() async throws -> [NetworkSummary]

    /// Backing command: `container network create [--label k=v ...]
    /// [--internal] [--subnet cidr] [--subnet-v6 cidr] <name>`.
    func createNetwork(_ spec: NetworkCreateSpec) async throws

    /// P1 source-compatible requirement. New consumers should prefer the
    /// spec overload above.
    func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws

    /// Backing command: `container network delete <name>`.
    func deleteNetwork(name: String) async throws

    /// Backing command: `container network prune`.
    func pruneNetworks() async throws -> PruneReport

    // MARK: Machines

    /// Backing command: `container machine list --format json`.
    func listMachines() async throws -> [MachineSummary]

    /// Backing command: `container machine inspect <id>` (JSON is emitted
    /// unconditionally; this command accepts no `--format` flag).
    func inspectMachine(id: String) async throws -> MachineDetail

    /// Backing command: `container machine create ...`.
    @discardableResult
    func createMachine(_ spec: MachineCreateSpec) async throws -> String

    /// Capsule semantic boot operation. Apple container 1.1 has no
    /// `machine start`; the CLI client uses boot-on-run with a root `true`
    /// command, matching Apple's own integration-test helper.
    func startMachine(id: String) async throws

    /// Backing command: `container machine stop <id>`.
    func stopMachine(id: String) async throws

    /// Backing command: `container machine delete <id>`.
    func deleteMachine(id: String) async throws

    /// Backing command: `container machine logs [--boot] [--follow]`.
    func machineLogs(
        id: String,
        source: MachineLogSource,
        follow: Bool,
        tail: Int?
    ) async throws -> AsyncThrowingStream<LogLine, Error>
}

extension ContainerRuntime {
    /// Source-compat shim for pre-contract call sites (App ContainersView).
    public func stopContainer(id: String) async throws { try await stopContainer(id: id, timeoutSeconds: nil) }

    /// Source-compatible witness for existing hand-written conformers.
    /// Default execution delegates to their original requirement; identity
    /// overrides fail loudly until that runtime explicitly supports them.
    public func exec(
        id: String,
        argv: [String],
        options: ExecOptions,
        timeout: Duration
    ) async throws -> ExecResult {
        guard options.user == nil else {
            throw RuntimeError.notImplemented(operation: "exec user override")
        }
        return try await exec(id: id, argv: argv, timeout: timeout)
    }

    /// Source-compatible convenience retained for P1 callers.
    public func createVolume(name: String, labels: [String: String]) async throws {
        try await createVolume(VolumeCreateSpec(name: name, labels: labels))
    }

    /// Lets P1 hand-written conformers remain source-compatible. They keep
    /// their old create method and fail loudly if a new consumer asks them to
    /// understand the richer spec before they adopt it.
    public func createVolume(_ spec: VolumeCreateSpec) async throws {
        throw RuntimeError.notImplemented(operation: "createVolume(VolumeCreateSpec)")
    }

    /// Source-compatible convenience retained for P1 callers.
    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        try await createNetwork(NetworkCreateSpec(
            name: name,
            connectivity: isInternal ? .hostOnly : .nat,
            labels: labels
        ))
    }
    /// Lets P1 hand-written conformers remain source-compatible. They fail
    /// loudly for the new spec rather than silently dropping its subnets.
    public func createNetwork(_ spec: NetworkCreateSpec) async throws {
        throw RuntimeError.notImplemented(operation: "createNetwork(NetworkCreateSpec)")
    }

    public func buildImage(_ spec: ImageBuildSpec) async throws -> AsyncThrowingStream<BuildProgress, Error> {
        throw RuntimeError.notImplemented(operation: "buildImage")
    }

    public func builderStatus() async throws -> BuilderStatus {
        throw RuntimeError.notImplemented(operation: "builderStatus")
    }

    public func startBuilder(_ configuration: BuilderConfiguration) async throws {
        throw RuntimeError.notImplemented(operation: "startBuilder")
    }

    public func stopBuilder() async throws {
        throw RuntimeError.notImplemented(operation: "stopBuilder")
    }

    public func deleteBuilder(force: Bool) async throws {
        throw RuntimeError.notImplemented(operation: "deleteBuilder")
    }

    public func pruneVolumes() async throws -> PruneReport {
        throw RuntimeError.notImplemented(operation: "pruneVolumes")
    }

    public func pruneNetworks() async throws -> PruneReport {
        throw RuntimeError.notImplemented(operation: "pruneNetworks")
    }

    public func listMachines() async throws -> [MachineSummary] {
        throw RuntimeError.notImplemented(operation: "listMachines")
    }

    public func inspectMachine(id: String) async throws -> MachineDetail {
        throw RuntimeError.notImplemented(operation: "inspectMachine")
    }

    public func createMachine(_ spec: MachineCreateSpec) async throws -> String {
        throw RuntimeError.notImplemented(operation: "createMachine")
    }

    public func startMachine(id: String) async throws {
        throw RuntimeError.notImplemented(operation: "startMachine")
    }

    public func stopMachine(id: String) async throws {
        throw RuntimeError.notImplemented(operation: "stopMachine")
    }

    public func deleteMachine(id: String) async throws {
        throw RuntimeError.notImplemented(operation: "deleteMachine")
    }

    public func machineLogs(
        id: String,
        source: MachineLogSource,
        follow: Bool,
        tail: Int?
    ) async throws -> AsyncThrowingStream<LogLine, Error> {
        throw RuntimeError.notImplemented(operation: "machineLogs")
    }
}

public enum RuntimeError: Error, Sendable {
    case resourceNotFound(kind: String, id: String)
    case binaryNotFound(searched: [String])
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(command: String, detail: String)
    case notImplemented(operation: String)
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .resourceNotFound(let kind, let id):
            return "\(kind) not found: \(id)"
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
        // The override is validated the same way the other two candidates
        // are (P1D fix, 2026-07-13): previously an override pointing at a
        // nonexistent path was trusted blindly and returned as-is, so every
        // caller downstream of `locate()` (`doctor`, `ls`, `runtime status`,
        // `RuntimeSession`) saw a bogus "found" binary path and then a raw
        // `SubprocessError`/`Process` failure instead of the clean
        // `RuntimeError.binaryNotFound` guidance — exactly the
        // `CAPSULE_CONTAINER_BIN=/nonexistent` smoke test this locator exists
        // to support. An invalid override does not fall through to the real
        // default path/`$PATH` search — its whole purpose is to let a caller
        // pin (or, for tests, simulate the absence of) a specific binary
        // deterministically, regardless of what's actually installed on the
        // host.
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
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
