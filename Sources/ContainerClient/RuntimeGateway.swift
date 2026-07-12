import Foundation

/// Decorator over any `ContainerRuntime` that serializes same-resource
/// mutating calls while letting reads and streams run fully concurrently
/// (plan §2.2). Compose consumers wrap the base client once at startup:
/// `RuntimeGateway(base: CLIProcessClient(...))`.
///
/// **Why serialize at all:** the underlying CLI has no compare-and-swap or
/// locking of its own — two concurrent `container start web-1` /
/// `container delete web-1` invocations race at the process level with
/// undefined interleaving. The gateway gives every caller of a given
/// resource id a strict FIFO ordering without requiring `ComposeRuntime` (or
/// any other consumer) to hand-roll its own per-id locking.
///
/// **What's serialized (per-id task chaining):** `startContainer`,
/// `stopContainer`, `killContainer`, `deleteContainer`, `createContainer`
/// (keyed by `spec.name` when present; an unnamed create gets a fresh unique
/// key per call so concurrent unnamed creates never contend — there is no
/// shared identity to serialize on until the runtime assigns one),
/// `deleteImage`/`tagImage` (keyed by the source reference), `createVolume`/
/// `deleteVolume`, `createNetwork`/`deleteNetwork`.
///
/// **What's pass-through (concurrent):** every list, `inspectContainer`,
/// `systemStatus`, `systemDiskUsage`, `cliVersion`, `logs`, `exec`, `stats`,
/// and `pullImage` — none of these mutate shared resource state on their
/// own, so there is nothing to order them against.
///
/// **Accepted residual race:** `pullImage` is pass-through (a long-lived
/// stream), so a concurrent `deleteImage` for the *same* reference is not
/// serialized behind an in-flight pull of that reference — serializing a
/// stream would hold that resource's lane for the stream's entire lifetime,
/// starving every other mutation of it for as long as the pull runs. If a
/// caller does this, the underlying CLI fails loudly (a real
/// `RuntimeError.commandFailed` with the real stderr) rather than silently
/// corrupting state; this is a deliberate scope cut, not an oversight.
///
/// **Mechanism** (swift-concurrency-pro `actors.md`/`cancellation.md`): each
/// serialized call captures `previous = tails[key]`, launches an unstructured
/// `Task` that awaits `previous` first (so ordering is FIFO per key)
/// and then runs the base call, and stores that task's erased completion as
/// the new tail. The caller awaits the result through
/// `withTaskCancellationHandler`, explicitly cancelling the inner `Task` on
/// cancel — an unstructured `Task {}` does not inherit the calling task's
/// cancellation automatically, so this propagation has to be manual. (The
/// base `CLIProcessClient` calls honor that cancellation via `Subprocess`'s
/// own SIGTERM→grace→SIGKILL escalation path, spike S5.) The tail is removed
/// after completion **only if it is still the stored tail** — a
/// compare-by-identity check — because another caller may already have
/// chained a newer tail onto ours while we were awaiting (actor reentrancy:
/// never assume `tails[key]` is unchanged after an `await`). All mutation of
/// `tails` is actor-isolated.
public actor RuntimeGateway: ContainerRuntime {
    public enum ResourceKey: Hashable, Sendable {
        case container(String)
        case image(String)
        case volume(String)
        case network(String)
    }

    private let base: any ContainerRuntime
    private var tails: [ResourceKey: TailEntry] = [:]

    public init(base: any ContainerRuntime) {
        self.base = base
    }

    // MARK: - System (pass-through)

    public func cliVersion() async throws -> SemanticVersion {
        try await base.cliVersion()
    }

    public func systemStatus() async throws -> SystemStatus {
        try await base.systemStatus()
    }

    public func systemDiskUsage() async throws -> SystemDiskUsage {
        try await base.systemDiskUsage()
    }

    // MARK: - Containers

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        try await base.listContainers(all: all)
    }

    public func inspectContainer(id: String) async throws -> ContainerDetail {
        try await base.inspectContainer(id: id)
    }

    public func createContainer(_ spec: RunSpec) async throws -> String {
        let key: ResourceKey = spec.name.map { .container($0) } ?? .container("unnamed:\(UUID().uuidString)")
        let base = self.base
        return try await serialized(key: key) { try await base.createContainer(spec) }
    }

    public func startContainer(id: String) async throws {
        let base = self.base
        try await serialized(key: .container(id)) { try await base.startContainer(id: id) }
    }

    public func stopContainer(id: String, timeoutSeconds: Int?) async throws {
        let base = self.base
        try await serialized(key: .container(id)) {
            try await base.stopContainer(id: id, timeoutSeconds: timeoutSeconds)
        }
    }

    public func killContainer(id: String, signal: String) async throws {
        let base = self.base
        try await serialized(key: .container(id)) { try await base.killContainer(id: id, signal: signal) }
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        let base = self.base
        try await serialized(key: .container(id)) { try await base.deleteContainer(id: id, force: force) }
    }

    public func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        try await base.logs(id: id, follow: follow, tail: tail)
    }

    public func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        try await base.exec(id: id, argv: argv, timeout: timeout)
    }

    public func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        try await base.stats(ids: ids)
    }

    // MARK: - Images

    public func listImages() async throws -> [ImageSummary] {
        try await base.listImages()
    }

    public func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        try await base.pullImage(reference: reference, platform: platform)
    }

    public func deleteImage(reference: String) async throws {
        let base = self.base
        try await serialized(key: .image(reference)) { try await base.deleteImage(reference: reference) }
    }

    public func tagImage(source: String, target: String) async throws {
        let base = self.base
        try await serialized(key: .image(source)) { try await base.tagImage(source: source, target: target) }
    }

    // MARK: - Volumes

    public func listVolumes() async throws -> [VolumeSummary] {
        try await base.listVolumes()
    }

    public func createVolume(name: String, labels: [String: String]) async throws {
        let base = self.base
        try await serialized(key: .volume(name)) { try await base.createVolume(name: name, labels: labels) }
    }

    public func deleteVolume(name: String) async throws {
        let base = self.base
        try await serialized(key: .volume(name)) { try await base.deleteVolume(name: name) }
    }

    // MARK: - Networks

    public func listNetworks() async throws -> [NetworkSummary] {
        try await base.listNetworks()
    }

    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        let base = self.base
        try await serialized(key: .network(name)) {
            try await base.createNetwork(name: name, labels: labels, isInternal: isInternal)
        }
    }

    public func deleteNetwork(name: String) async throws {
        let base = self.base
        try await serialized(key: .network(name)) { try await base.deleteNetwork(name: name) }
    }

    // MARK: - Serialization mechanism

    fileprivate struct TailEntry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private func serialized<T: Sendable>(
        key: ResourceKey,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previousTail = tails[key]?.task
        let myID = UUID()

        // FIFO chain: wait for whatever was queued ahead of us (tolerating
        // its failure — a failed prior op still must not block the next
        // one), then run the real operation.
        let opTask = Task<T, Error> {
            _ = await previousTail?.value
            return try await operation()
        }
        // Erase `opTask`'s value/error into a plain completion signal so the
        // *next* caller only needs to know "has this lane's prior work
        // finished," not what it returned.
        let tailTask = Task<Void, Never> {
            _ = try? await opTask.value
        }
        tails[key] = TailEntry(id: myID, task: tailTask)

        do {
            let result = try await withTaskCancellationHandler {
                try await opTask.value
            } onCancel: {
                opTask.cancel()
            }
            clearTailIfCurrent(key: key, id: myID)
            return result
        } catch {
            clearTailIfCurrent(key: key, id: myID)
            throw error
        }
    }

    /// Compare-and-remove: only clears `tails[key]` if it is still the tail
    /// *this* call installed. Another caller may have already chained a
    /// newer tail onto ours while we were awaiting our own completion —
    /// removing unconditionally would drop that newer lane's entry and let a
    /// third caller run concurrently with it instead of behind it.
    private func clearTailIfCurrent(key: ResourceKey, id: UUID) {
        if tails[key]?.id == id {
            tails[key] = nil
        }
    }
}
