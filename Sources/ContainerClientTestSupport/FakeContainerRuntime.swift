import ContainerClient
import Foundation

/// In-memory `ContainerRuntime` for tests across every package that consumes
/// the runtime protocol (ComposeRuntime, Supervisor, App). Fully configurable
/// canned responses + a recorded call log — no subprocess, no real state
/// transitions. Actor-isolated so it is safely shareable across concurrent
/// test tasks.
public actor FakeContainerRuntime: ContainerRuntime {
    /// One case per `ContainerRuntime` method (the source of truth for
    /// `setError`/`clearError` targeting).
    public enum Operation: String, Sendable, CaseIterable {
        case cliVersion, systemStatus, systemDiskUsage, systemStart, systemStop
        case listContainers, inspectContainer, createContainer, startContainer
        case stopContainer, killContainer, deleteContainer, logs, exec, stats
        case listImages, pullImage, deleteImage, tagImage
        case listVolumes, createVolume, deleteVolume
        case listNetworks, createNetwork, deleteNetwork
    }

    /// One case per `ContainerRuntime` method, carrying the exact arguments
    /// it was called with — asserted against in order by call-sequence tests.
    public enum Call: Sendable, Equatable {
        case cliVersion
        case systemStatus
        case systemDiskUsage
        case systemStart
        case systemStop
        case listContainers(all: Bool)
        case inspectContainer(id: String)
        case createContainer(RunSpec)
        case startContainer(id: String)
        case stopContainer(id: String, timeoutSeconds: Int?)
        case killContainer(id: String, signal: String)
        case deleteContainer(id: String, force: Bool)
        case logs(id: String, follow: Bool, tail: Int?)
        case exec(id: String, argv: [String], timeout: Duration)
        case stats(ids: [String])
        case listImages
        case pullImage(reference: String, platform: String?)
        case deleteImage(reference: String)
        case tagImage(source: String, target: String)
        case listVolumes
        case createVolume(name: String, labels: [String: String])
        case deleteVolume(name: String)
        case listNetworks
        case createNetwork(name: String, labels: [String: String], isInternal: Bool)
        case deleteNetwork(name: String)
    }

    public private(set) var calls: [Call] = []

    private var cliVersionValue: SemanticVersion
    private var systemStatusValue: SystemStatus
    private var diskUsageValue: SystemDiskUsage
    private var containersValue: [ContainerSummary] = []
    private var detailsByID: [String: ContainerDetail] = [:]
    private var logLinesByID: [String: [LogLine]] = [:]
    private var statsTicks: [[StatsSample]] = []
    private var execResultsByID: [String: ExecResult] = [:]
    private var imagesValue: [ImageSummary] = []
    private var pullEventsByReference: [String: [PullProgress]] = [:]
    private var volumesValue: [VolumeSummary] = []
    private var networksValue: [NetworkSummary] = []
    private var errors: [Operation: any Error] = [:]
    private var createCounter = 0

    public init() {
        cliVersionValue = SemanticVersion(major: 1, minor: 1, patch: 0)
        systemStatusValue = SystemStatus(status: "running")
        diskUsageValue = SystemDiskUsage(
            containers: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0),
            images: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0),
            volumes: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0)
        )
    }

    // MARK: - Stubbers

    public func setCLIVersion(_ version: SemanticVersion) {
        cliVersionValue = version
    }

    public func setSystemStatus(_ status: SystemStatus) {
        systemStatusValue = status
    }

    public func setDiskUsage(_ usage: SystemDiskUsage) {
        diskUsageValue = usage
    }

    public func setContainers(_ containers: [ContainerSummary]) {
        containersValue = containers
    }

    public func setDetail(_ detail: ContainerDetail, forID id: String) {
        detailsByID[id] = detail
    }

    public func setLogLines(_ lines: [LogLine], forID id: String) {
        logLinesByID[id] = lines
    }

    public func setStatsTicks(_ ticks: [[StatsSample]]) {
        statsTicks = ticks
    }

    public func setExecResult(_ result: ExecResult, forID id: String) {
        execResultsByID[id] = result
    }

    public func setImages(_ images: [ImageSummary]) {
        imagesValue = images
    }

    public func setPullEvents(_ events: [PullProgress], forReference reference: String) {
        pullEventsByReference[reference] = events
    }

    public func setVolumes(_ volumes: [VolumeSummary]) {
        volumesValue = volumes
    }

    public func setNetworks(_ networks: [NetworkSummary]) {
        networksValue = networks
    }

    /// Makes `operation` throw `error` on every subsequent call until
    /// `clearError(for:)` is called. The call is still recorded before the
    /// injected error is thrown.
    public func setError<E: Error & Sendable>(_ error: E, for operation: Operation) {
        errors[operation] = error
    }

    public func clearError(for operation: Operation) {
        errors[operation] = nil
    }

    /// Restores every stub and the call log to their `init()` defaults.
    public func reset() {
        calls = []
        cliVersionValue = SemanticVersion(major: 1, minor: 1, patch: 0)
        systemStatusValue = SystemStatus(status: "running")
        diskUsageValue = SystemDiskUsage(
            containers: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0),
            images: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0),
            volumes: ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimableBytes: 0)
        )
        containersValue = []
        detailsByID = [:]
        logLinesByID = [:]
        statsTicks = []
        execResultsByID = [:]
        imagesValue = []
        pullEventsByReference = [:]
        volumesValue = []
        networksValue = []
        errors = [:]
        createCounter = 0
    }

    private func record(_ call: Call, operation: Operation) throws {
        calls.append(call)
        if let error = errors[operation] { throw error }
    }

    // MARK: - ContainerRuntime

    public func cliVersion() async throws -> SemanticVersion {
        try record(.cliVersion, operation: .cliVersion)
        return cliVersionValue
    }

    public func systemStatus() async throws -> SystemStatus {
        try record(.systemStatus, operation: .systemStatus)
        return systemStatusValue
    }

    public func systemDiskUsage() async throws -> SystemDiskUsage {
        try record(.systemDiskUsage, operation: .systemDiskUsage)
        return diskUsageValue
    }

    public func systemStart() async throws {
        try record(.systemStart, operation: .systemStart)
    }

    public func systemStop() async throws {
        try record(.systemStop, operation: .systemStop)
    }

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        try record(.listContainers(all: all), operation: .listContainers)
        return containersValue
    }

    public func inspectContainer(id: String) async throws -> ContainerDetail {
        try record(.inspectContainer(id: id), operation: .inspectContainer)
        guard let detail = detailsByID[id] else {
            throw RuntimeError.commandFailed(
                command: "container inspect \(id)",
                exitCode: 1,
                stderr: "no such container: \(id)"
            )
        }
        return detail
    }

    public func createContainer(_ spec: RunSpec) async throws -> String {
        try record(.createContainer(spec), operation: .createContainer)
        createCounter += 1
        return spec.name ?? "fake-\(createCounter)"
    }

    public func startContainer(id: String) async throws {
        try record(.startContainer(id: id), operation: .startContainer)
    }

    public func stopContainer(id: String, timeoutSeconds: Int?) async throws {
        try record(.stopContainer(id: id, timeoutSeconds: timeoutSeconds), operation: .stopContainer)
    }

    public func killContainer(id: String, signal: String) async throws {
        try record(.killContainer(id: id, signal: signal), operation: .killContainer)
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        try record(.deleteContainer(id: id, force: force), operation: .deleteContainer)
    }

    public func logs(id: String, follow: Bool, tail: Int?) async throws -> AsyncThrowingStream<LogLine, Error> {
        try record(.logs(id: id, follow: follow, tail: tail), operation: .logs)
        let lines = logLinesByID[id] ?? []
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LogLine.self)
        for line in lines { continuation.yield(line) }
        continuation.finish()
        return stream
    }

    public func exec(id: String, argv: [String], timeout: Duration) async throws -> ExecResult {
        try record(.exec(id: id, argv: argv, timeout: timeout), operation: .exec)
        return execResultsByID[id] ?? ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    public func stats(ids: [String]) async throws -> AsyncThrowingStream<[StatsSample], Error> {
        try record(.stats(ids: ids), operation: .stats)
        let ticks = statsTicks
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [StatsSample].self)
        for tick in ticks { continuation.yield(tick) }
        continuation.finish()
        return stream
    }

    public func listImages() async throws -> [ImageSummary] {
        try record(.listImages, operation: .listImages)
        return imagesValue
    }

    public func pullImage(reference: String, platform: String?) async throws -> AsyncThrowingStream<PullProgress, Error> {
        try record(.pullImage(reference: reference, platform: platform), operation: .pullImage)
        let events = pullEventsByReference[reference] ?? []
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PullProgress.self)
        for event in events { continuation.yield(event) }
        continuation.finish()
        return stream
    }

    public func deleteImage(reference: String) async throws {
        try record(.deleteImage(reference: reference), operation: .deleteImage)
    }

    public func tagImage(source: String, target: String) async throws {
        try record(.tagImage(source: source, target: target), operation: .tagImage)
    }

    public func listVolumes() async throws -> [VolumeSummary] {
        try record(.listVolumes, operation: .listVolumes)
        return volumesValue
    }

    public func createVolume(name: String, labels: [String: String]) async throws {
        try record(.createVolume(name: name, labels: labels), operation: .createVolume)
    }

    public func deleteVolume(name: String) async throws {
        try record(.deleteVolume(name: name), operation: .deleteVolume)
    }

    public func listNetworks() async throws -> [NetworkSummary] {
        try record(.listNetworks, operation: .listNetworks)
        return networksValue
    }

    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws {
        try record(.createNetwork(name: name, labels: labels, isInternal: isInternal), operation: .createNetwork)
    }

    public func deleteNetwork(name: String) async throws {
        try record(.deleteNetwork(name: name), operation: .deleteNetwork)
    }
}
