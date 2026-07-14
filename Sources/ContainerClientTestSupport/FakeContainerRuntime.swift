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
        case cliVersion, systemStatus, defaultKernelReadiness, systemDiskUsage, systemStart, systemStop
        case listContainers, inspectContainer, createContainer, startContainer
        case stopContainer, killContainer, deleteContainer, logs, exec, stats
        case listImages, pullImage, deleteImage, tagImage, buildImage
        case builderStatus, startBuilder, stopBuilder, deleteBuilder
        case listVolumes, createVolume, deleteVolume, pruneVolumes
        case listNetworks, createNetwork, deleteNetwork, pruneNetworks
        case listMachines, inspectMachine, createMachine, startMachine
        case stopMachine, deleteMachine, machineLogs
    }

    /// One case per `ContainerRuntime` method, carrying the exact arguments
    /// it was called with — asserted against in order by call-sequence tests.
    public enum Call: Sendable, Equatable {
        case cliVersion
        case systemStatus
        case defaultKernelReadiness
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
        case execWithOptions(id: String, argv: [String], options: ExecOptions, timeout: Duration)
        case stats(ids: [String])
        case listImages
        case pullImage(reference: String, platform: String?)
        case deleteImage(reference: String)
        case tagImage(source: String, target: String)
        case buildImage(ImageBuildSpec)
        case builderStatus
        case startBuilder(BuilderConfiguration)
        case stopBuilder
        case deleteBuilder(force: Bool)
        case listVolumes
        case createVolume(VolumeCreateSpec)
        case deleteVolume(name: String)
        case pruneVolumes
        case listNetworks
        case createNetwork(NetworkCreateSpec)
        case deleteNetwork(name: String)
        case pruneNetworks
        case listMachines
        case inspectMachine(id: String)
        case createMachine(MachineCreateSpec)
        case startMachine(id: String)
        case stopMachine(id: String)
        case deleteMachine(id: String)
        case machineLogs(id: String, source: MachineLogSource, follow: Bool, tail: Int?)
    }

    public private(set) var calls: [Call] = []

    private var cliVersionValue: SemanticVersion
    private var systemStatusValue: SystemStatus
    private var defaultKernelReadinessValue: DefaultKernelReadiness
    private var diskUsageValue: SystemDiskUsage
    private var containersValue: [ContainerSummary] = []
    private var detailsByID: [String: ContainerDetail] = [:]
    private var logLinesByID: [String: [LogLine]] = [:]
    private var statsTicks: [[StatsSample]] = []
    private var execResultsByID: [String: ExecResult] = [:]
    private var imagesValue: [ImageSummary] = []
    private var pullEventsByReference: [String: [PullProgress]] = [:]
    private var buildEventsByTag: [String: [BuildProgress]] = [:]
    private var builderStatusValue = BuilderStatus.absent
    private var volumesValue: [VolumeSummary] = []
    private var networksValue: [NetworkSummary] = []
    private var machinesValue: [MachineSummary] = []
    private var machineDetailsByID: [String: MachineDetail] = [:]
    private var machineLogLinesByID: [String: [LogLine]] = [:]
    private var volumePruneReport = PruneReport(removedNames: [])
    private var networkPruneReport = PruneReport(removedNames: [])
    private var errors: [Operation: any Error] = [:]
    private var createCounter = 0

    public init() {
        cliVersionValue = SemanticVersion(major: 1, minor: 1, patch: 0)
        systemStatusValue = SystemStatus(status: "running")
        defaultKernelReadinessValue = .configured()
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

    public func setDefaultKernelReadiness(_ readiness: DefaultKernelReadiness) {
        defaultKernelReadinessValue = readiness
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

    public func setBuildEvents(_ events: [BuildProgress], forTag tag: String) {
        buildEventsByTag[tag] = events
    }

    public func setBuilderStatus(_ status: BuilderStatus) {
        builderStatusValue = status
    }

    public func setVolumes(_ volumes: [VolumeSummary]) {
        volumesValue = volumes
    }

    public func setNetworks(_ networks: [NetworkSummary]) {
        networksValue = networks
    }

    public func setMachines(_ machines: [MachineSummary]) {
        machinesValue = machines
    }

    public func setMachineDetail(_ detail: MachineDetail, forID id: String) {
        machineDetailsByID[id] = detail
    }

    public func setMachineLogLines(_ lines: [LogLine], forID id: String) {
        machineLogLinesByID[id] = lines
    }

    public func setVolumePruneReport(_ report: PruneReport) {
        volumePruneReport = report
    }

    public func setNetworkPruneReport(_ report: PruneReport) {
        networkPruneReport = report
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
        defaultKernelReadinessValue = .configured()
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
        buildEventsByTag = [:]
        builderStatusValue = .absent
        volumesValue = []
        networksValue = []
        machinesValue = []
        machineDetailsByID = [:]
        machineLogLinesByID = [:]
        volumePruneReport = PruneReport(removedNames: [])
        networkPruneReport = PruneReport(removedNames: [])
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

    public func defaultKernelReadiness() async throws -> DefaultKernelReadiness {
        try record(.defaultKernelReadiness, operation: .defaultKernelReadiness)
        return defaultKernelReadinessValue
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

    public func exec(
        id: String,
        argv: [String],
        options: ExecOptions,
        timeout: Duration
    ) async throws -> ExecResult {
        guard options.user != nil else {
            return try await exec(id: id, argv: argv, timeout: timeout)
        }
        try record(
            .execWithOptions(id: id, argv: argv, options: options, timeout: timeout),
            operation: .exec
        )
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

    public func buildImage(_ spec: ImageBuildSpec) async throws -> AsyncThrowingStream<BuildProgress, Error> {
        try record(.buildImage(spec), operation: .buildImage)
        let events = buildEventsByTag[spec.tag] ?? []
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: BuildProgress.self)
        for event in events { continuation.yield(event) }
        continuation.finish()
        return stream
    }

    public func builderStatus() async throws -> BuilderStatus {
        try record(.builderStatus, operation: .builderStatus)
        return builderStatusValue
    }

    public func startBuilder(_ configuration: BuilderConfiguration) async throws {
        try record(.startBuilder(configuration), operation: .startBuilder)
    }

    public func stopBuilder() async throws {
        try record(.stopBuilder, operation: .stopBuilder)
    }

    public func deleteBuilder(force: Bool) async throws {
        try record(.deleteBuilder(force: force), operation: .deleteBuilder)
    }

    public func listVolumes() async throws -> [VolumeSummary] {
        try record(.listVolumes, operation: .listVolumes)
        return volumesValue
    }

    public func createVolume(_ spec: VolumeCreateSpec) async throws {
        try record(.createVolume(spec), operation: .createVolume)
    }

    public func deleteVolume(name: String) async throws {
        try record(.deleteVolume(name: name), operation: .deleteVolume)
    }

    public func pruneVolumes() async throws -> PruneReport {
        try record(.pruneVolumes, operation: .pruneVolumes)
        return volumePruneReport
    }

    public func listNetworks() async throws -> [NetworkSummary] {
        try record(.listNetworks, operation: .listNetworks)
        return networksValue
    }

    public func createNetwork(_ spec: NetworkCreateSpec) async throws {
        try record(.createNetwork(spec), operation: .createNetwork)
    }

    public func deleteNetwork(name: String) async throws {
        try record(.deleteNetwork(name: name), operation: .deleteNetwork)
    }

    public func pruneNetworks() async throws -> PruneReport {
        try record(.pruneNetworks, operation: .pruneNetworks)
        return networkPruneReport
    }

    public func listMachines() async throws -> [MachineSummary] {
        try record(.listMachines, operation: .listMachines)
        return machinesValue
    }

    public func inspectMachine(id: String) async throws -> MachineDetail {
        try record(.inspectMachine(id: id), operation: .inspectMachine)
        guard let detail = machineDetailsByID[id] else {
            throw RuntimeError.resourceNotFound(kind: "machine", id: id)
        }
        return detail
    }

    public func createMachine(_ spec: MachineCreateSpec) async throws -> String {
        try record(.createMachine(spec), operation: .createMachine)
        return spec.name ?? "fake-machine"
    }

    public func startMachine(id: String) async throws {
        try record(.startMachine(id: id), operation: .startMachine)
    }

    public func stopMachine(id: String) async throws {
        try record(.stopMachine(id: id), operation: .stopMachine)
    }

    public func deleteMachine(id: String) async throws {
        try record(.deleteMachine(id: id), operation: .deleteMachine)
    }

    public func machineLogs(
        id: String,
        source: MachineLogSource,
        follow: Bool,
        tail: Int?
    ) async throws -> AsyncThrowingStream<LogLine, Error> {
        try record(
            .machineLogs(id: id, source: source, follow: follow, tail: tail),
            operation: .machineLogs
        )
        let values = machineLogLinesByID[id] ?? []
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LogLine.self)
        for value in values { continuation.yield(value) }
        continuation.finish()
        return stream
    }
}
