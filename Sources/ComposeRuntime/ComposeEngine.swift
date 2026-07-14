import ComposePlanner
import ComposeSpec
import ContainerClient
import CryptoKit
import Foundation
import ProjectStore
import Supervisor

public actor ComposeEngine {
    private let runtime: any ContainerRuntime
    private let store: ProjectStore
    private let stateCoordinator: ProjectStateCoordinator
    private let parser: ComposeParser

    public init(
        runtime: any ContainerRuntime,
        store: ProjectStore = ProjectStore(),
        stateCoordinator: ProjectStateCoordinator? = nil,
        parser: ComposeParser = ComposeParser()
    ) {
        self.runtime = runtime
        self.store = store
        self.stateCoordinator = stateCoordinator ?? ProjectStateCoordinator(store: store)
        self.parser = parser
    }

    public func open(_ source: ComposeSource) throws -> ComposeProject {
        let document = try parser.parse(source: source)
        return ComposeProject(
            runtime: runtime,
            store: store,
            stateCoordinator: stateCoordinator,
            source: source,
            document: document
        )
    }
}

public actor ComposeProject {
    private let runtime: any ContainerRuntime
    private let store: ProjectStore
    private let stateCoordinator: ProjectStateCoordinator
    private let source: ComposeSource
    private let document: ComposeDocument
    private let planner = Planner()
    private let executor: ComposeExecutor

    init(
        runtime: any ContainerRuntime,
        store: ProjectStore,
        stateCoordinator: ProjectStateCoordinator,
        source: ComposeSource,
        document: ComposeDocument
    ) {
        self.runtime = runtime
        self.store = store
        self.stateCoordinator = stateCoordinator
        self.source = source
        self.document = document
        self.executor = ComposeExecutor(runtime: runtime)
    }

    public func configuration() -> ComposeDocument { document }

    public func dependencyGraph() throws -> ComposeDependencyGraph {
        let dependencies = document.file.services.mapValues { service in
            Set(service.dependsOn?.requirements.keys.map { $0 } ?? [])
        }
        let edges = document.file.services.flatMap { dependent, service in
            (service.dependsOn?.requirements ?? [:]).map { dependency, requirement in
                ComposeDependencyGraph.Edge(
                    dependency: dependency,
                    dependent: dependent,
                    condition: requirement.condition
                )
            }
        }.sorted {
            ($0.dependency, $0.dependent, $0.condition.rawValue)
                < ($1.dependency, $1.dependent, $1.condition.rawValue)
        }
        return ComposeDependencyGraph(
            services: document.file.services.keys.sorted(),
            edges: edges,
            startLayers: try DependencyGraph.startLayers(dependencies)
        )
    }

    public func prepareUp(_ request: UpRequest = UpRequest()) async throws -> PreparedUp {
        var observed = try await observedState()
        if request.build {
            for (service, config) in document.file.services where config.build != nil {
                if var state = observed.services[service] {
                    state.configHash = nil
                    observed.services[service] = state
                }
            }
        }
        let plan = try planner.makePlan(
            for: document,
            observed: observed,
            options: request.planningOptions
        )
        return PreparedUp(
            source: source,
            document: document,
            request: request,
            revision: try Self.revision(source: source, plan: plan),
            plan: plan
        )
    }

    public func up(_ prepared: PreparedUp) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let current = try await prepareUp(prepared.request)
        guard prepared.source == source, prepared.document == document,
              current.revision == prepared.revision, current.plan == prepared.plan
        else {
            throw ComposeRuntimeError.stalePreparedPlan(
                expected: prepared.revision,
                actual: current.revision
            )
        }

        let kernelReadiness = try await runtime.defaultKernelReadiness()
        guard kernelReadiness.isConfigured else {
            throw ComposeRuntimeError.defaultKernelNotConfigured(
                architecture: kernelReadiness.architecture
            )
        }

        try await persistDesiredState(
            running: true,
            selectedServices: Set(prepared.request.services)
        )
        let stateCoordinator = self.stateCoordinator
        let projectID = document.projectName
        return await executor.execute(
            prepared.plan,
            kind: .up,
            onHealthObservation: { service, containerID, observation in
                let initial = StoredProjectState(
                    revision: prepared.revision.rawValue,
                    desiredRunning: true,
                    serviceConfigHashes: [:]
                )
                try await stateCoordinator.update(projectID: projectID, initial: initial) { state in
                    var serviceState = state.services[service]
                        ?? StoredServiceState(containerID: containerID, desiredRunning: true)
                    serviceState.containerID = containerID
                    serviceState.healthObservation = StoredHealthObservation(
                        state: StoredHealthState(rawValue: observation.state.rawValue) ?? .starting,
                        attempt: observation.attempt,
                        output: observation.output,
                        observedAt: .now
                    )
                    state.services[service] = serviceState
                }
            }
        )
    }

    public func status() async throws -> ComposeProjectStatus {
        let containers = try await runtime.listContainers(all: true)
            .filter { $0.labels["capsule.project"] == document.projectName }
        let desiredPlan = try planner.makePlan(for: document)
        let stored = try? await stateCoordinator.load(projectID: document.projectName)
        let desired = desiredPlan.steps.compactMap { step -> DesiredServiceInstance? in
            guard case .ensureContainer(let service, let spec) = step else { return nil }
            return DesiredServiceInstance(
                service: service,
                index: Int(spec.labels["capsule.index"] ?? "1") ?? 1,
                containerName: spec.name ?? service,
                configHash: spec.labels["capsule.config-hash"] ?? "",
                shouldRun: stored?.services[service]?.desiredRunning
                    ?? stored?.desiredRunning
                    ?? true
            )
        }
        let drift = DriftReconciler.report(
            project: document.projectName,
            desired: desired,
            observed: containers
        )
        let observedByService = Dictionary(
            containers.compactMap { container -> (String, ContainerSummary)? in
                guard let service = container.labels["capsule.service"] else { return nil }
                return (service, container)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let services = document.file.services.keys.sorted().map { service -> ComposeServiceStatus in
            let container = observedByService[service]
            let health = stored?.services[service]?.health.flatMap { HealthState(rawValue: $0.rawValue) }
            return ComposeServiceStatus(
                service: service,
                index: Int(container?.labels["capsule.index"] ?? "1") ?? 1,
                containerID: container?.id,
                runtimeState: container?.runState ?? .unknown,
                ports: container?.ports ?? [],
                configHash: container?.labels["capsule.config-hash"],
                health: health
            )
        }
        return ComposeProjectStatus(project: document.projectName, services: services, drift: drift)
    }

    public func down(_ request: DownRequest = DownRequest()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let runtime = self.runtime
        let stateCoordinator = self.stateCoordinator
        let project = document.projectName
        let configuredServices = Set(document.file.services.keys)
        let stopTimeouts = stopTimeoutsByService()
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ComposeEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        let task = Task(name: "Compose down \(project)") {
            let operationID = UUID()
            continuation.yield(.operationStarted(id: operationID, kind: .down))
            do {
                // Record user intent before the first runtime stop. A resident
                // restart watcher may observe that stopped edge immediately.
                if let previous = try? await stateCoordinator.load(projectID: project) {
                    try await stateCoordinator.update(projectID: project, initial: previous) { state in
                        state.desiredRunning = false
                        for service in state.services.keys {
                            state.services[service]?.desiredRunning = false
                            state.services[service]?.stoppedByUser = true
                        }
                    }
                }
                let containers = try await runtime.listContainers(all: true)
                    .filter {
                        guard $0.labels["capsule.project"] == project else { return false }
                        return request.removeOrphans
                            || configuredServices.contains($0.labels["capsule.service"] ?? "")
                    }
                for container in containers.sorted(by: { $0.id > $1.id }) {
                    try Task.checkCancellation()
                    if container.runState == .running {
                        let service = container.labels["capsule.service"] ?? ""
                        try await runtime.stopContainer(
                            id: container.id,
                            timeoutSeconds: stopTimeouts[service] ?? nil
                        )
                        continuation.yield(.operationOutput("stopped \(container.id)"))
                    }
                    try await runtime.deleteContainer(id: container.id, force: true)
                    continuation.yield(.operationOutput("removed \(container.id)"))
                }

                let networks = try await runtime.listNetworks()
                    .filter { $0.labels["capsule.project"] == project }
                for network in networks.sorted(by: { $0.name > $1.name }) {
                    try await runtime.deleteNetwork(name: network.name)
                    continuation.yield(.operationOutput("removed network \(network.name)"))
                }

                if request.removeVolumes {
                    let volumes = try await runtime.listVolumes()
                        .filter { $0.labels["capsule.project"] == project }
                    for volume in volumes.sorted(by: { $0.name > $1.name }) {
                        try await runtime.deleteVolume(name: volume.name)
                        continuation.yield(.operationOutput("removed volume \(volume.name)"))
                    }
                }

                continuation.yield(.operationCompleted(id: operationID, kind: .down))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    /// Read-only preview for the destructive `down` confirmation surface.
    /// It mirrors the same label/configured-service filters used by
    /// `down(_:)`, so the UI never guesses from rendered YAML.
    public func downPreview(removeOrphans: Bool = false) async throws -> ComposeDownPreview {
        let project = document.projectName
        let configuredServices = Set(document.file.services.keys)
        async let allContainers = runtime.listContainers(all: true)
        async let allNetworks = runtime.listNetworks()
        async let allVolumes = runtime.listVolumes()

        let (containers, networks, volumes) = try await (allContainers, allNetworks, allVolumes)
        return ComposeDownPreview(
            containers: containers
                .filter {
                    guard $0.labels["capsule.project"] == project else { return false }
                    return removeOrphans || configuredServices.contains($0.labels["capsule.service"] ?? "")
                }
                .map(\.id)
                .sorted(),
            networks: networks
                .filter { $0.labels["capsule.project"] == project }
                .map(\.name)
                .sorted(),
            volumes: volumes
                .filter { $0.labels["capsule.project"] == project }
                .map(\.name)
                .sorted()
        )
    }

    public func logs(
        _ query: ProjectLogQuery = ProjectLogQuery()
    ) async throws -> AsyncThrowingStream<ProjectLogEntry, Error> {
        let containers = try await runtime.listContainers(all: true).filter {
            $0.labels["capsule.project"] == document.projectName
                && query.selection.contains($0.labels["capsule.service"] ?? "")
        }
        let runtime = self.runtime
        let store = self.store
        let projectID = document.projectName
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ProjectLogEntry.self,
            bufferingPolicy: .bufferingNewest(4_096)
        )
        let task = Task(name: "Compose logs \(document.projectName)") {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for container in containers {
                        let service = container.labels["capsule.service"] ?? container.id
                        let index = Int(container.labels["capsule.index"] ?? "1") ?? 1
                        group.addTask {
                            let lines = try await runtime.logs(
                                id: container.id,
                                // A stopped container can still provide its
                                // tail, but following it may fail and cancel
                                // every running service's fan-in. Follow only
                                // live containers; include stopped history as
                                // a finite stream.
                                follow: query.follow && container.runState == .running,
                                tail: query.tail
                            )
                            for try await line in lines {
                                try store.appendLogLine(
                                    line.text,
                                    projectID: projectID,
                                    service: service
                                )
                                continuation.yield(ProjectLogEntry(
                                    service: service,
                                    index: index,
                                    containerID: container.id,
                                    line: line
                                ))
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func start(_ selection: ServiceSelection = ServiceSelection()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        try await serviceOperation(kind: .start, selection: selection, intent: .start) { runtime, container in
            try await runtime.startContainer(id: container.id)
        }
    }

    public func stop(_ selection: ServiceSelection = ServiceSelection()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let timeouts = stopTimeoutsByService()
        return try await serviceOperation(kind: .stop, selection: selection, intent: .stop) { runtime, container in
            let service = container.labels["capsule.service"] ?? ""
            try await runtime.stopContainer(id: container.id, timeoutSeconds: timeouts[service] ?? nil)
        }
    }

    public func restart(_ selection: ServiceSelection = ServiceSelection()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let timeouts = stopTimeoutsByService()
        return try await serviceOperation(kind: .restart, selection: selection, intent: .restart) { runtime, container in
            if container.runState == .running {
                let service = container.labels["capsule.service"] ?? ""
                try await runtime.stopContainer(id: container.id, timeoutSeconds: timeouts[service] ?? nil)
            }
            try await runtime.startContainer(id: container.id)
        }
    }

    /// Builds every selected service that declares `build:` without changing
    /// container state. The planner remains the single source of build specs.
    public func build(_ selection: ServiceSelection = ServiceSelection()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let prepared = try await prepareUp(UpRequest(services: selection.services, build: true))
        let plan = ExecutionPlan(layers: prepared.plan.layers.map { layer in
            PlanLayer(steps: layer.steps.filter {
                if case .ensureBuild = $0 { return true }
                return false
            })
        })
        return await executor.execute(plan, kind: .build)
    }

    /// Pulls images required by selected services without creating resources.
    public func pull(_ selection: ServiceSelection = ServiceSelection()) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let prepared = try await prepareUp(UpRequest(services: selection.services))
        let plan = ExecutionPlan(layers: prepared.plan.layers.map { layer in
            PlanLayer(steps: layer.steps.filter {
                if case .ensureImage = $0 { return true }
                return false
            })
        })
        return await executor.execute(plan, kind: .pull)
    }

    public func exec(service: String, argv: [String], timeout: Duration = .seconds(60)) async throws -> ExecResult {
        let container = try await container(for: service)
        return try await runtime.exec(id: container.id, argv: argv, timeout: timeout)
    }

    private func serviceOperation(
        kind: ComposeOperationKind,
        selection: ServiceSelection,
        intent: ServiceUserIntent,
        action: @escaping @Sendable (any ContainerRuntime, ContainerSummary) async throws -> Void
    ) async throws -> AsyncThrowingStream<ComposeEvent, Error> {
        let runtime = self.runtime
        let stateCoordinator = self.stateCoordinator
        let project = document.projectName
        let containers = try await runtime.listContainers(all: true).filter {
            $0.labels["capsule.project"] == project
                && selection.contains($0.labels["capsule.service"] ?? "")
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ComposeEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        let task = Task(name: "Compose \(kind.rawValue) \(project)") {
            let operationID = UUID()
            continuation.yield(.operationStarted(id: operationID, kind: kind))
            do {
                for container in containers {
                    try Task.checkCancellation()
                    let service = container.labels["capsule.service"] ?? container.id
                    let initial = (try? await stateCoordinator.load(projectID: project))
                        ?? StoredProjectState(
                            revision: "",
                            desiredRunning: intent != .stop,
                            serviceConfigHashes: [:]
                        )
                    try await stateCoordinator.update(projectID: project, initial: initial) { state in
                        var serviceState = state.services[service]
                            ?? StoredServiceState(
                                containerID: container.id,
                                desiredRunning: intent != .stop
                            )
                        serviceState.containerID = container.id
                        switch intent {
                        case .start:
                            serviceState.desiredRunning = true
                            serviceState.stoppedByUser = false
                            serviceState.restart.scheduledFor = nil
                            serviceState.restart.scheduledContainerID = nil
                            serviceState.restart.lastError = nil
                        case .stop:
                            serviceState.desiredRunning = false
                            serviceState.stoppedByUser = true
                        case .restart:
                            // Suppress the watcher for the intentional stopped
                            // edge; clear this only after start succeeds.
                            serviceState.desiredRunning = true
                            serviceState.stoppedByUser = true
                        }
                        state.services[service] = serviceState
                        state.desiredRunning = state.services.values.contains { $0.desiredRunning }
                    }
                    try await action(runtime, container)
                    if intent == .restart {
                        try await stateCoordinator.update(projectID: project, initial: initial) { state in
                            state.services[service]?.stoppedByUser = false
                            state.services[service]?.restart.scheduledFor = nil
                            state.services[service]?.restart.scheduledContainerID = nil
                            state.services[service]?.restart.lastError = nil
                        }
                    }
                    continuation.yield(.operationOutput("\(kind.rawValue) \(container.id)"))
                }
                continuation.yield(.operationCompleted(id: operationID, kind: kind))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private enum ServiceUserIntent: Sendable, Equatable {
        case start
        case stop
        case restart
    }

    private func container(for service: String) async throws -> ContainerSummary {
        let containers = try await runtime.listContainers(all: true)
        guard let container = containers.first(where: {
            $0.labels["capsule.project"] == document.projectName
                && $0.labels["capsule.service"] == service
        }) else {
            throw ComposeRuntimeError.missingContainer(service: service)
        }
        return container
    }

    private func observedState() async throws -> ObservedProjectState {
        async let containersCall = runtime.listContainers(all: true)
        async let volumesCall = runtime.listVolumes()
        async let networksCall = runtime.listNetworks()
        let (containers, volumes, networks) = try await (containersCall, volumesCall, networksCall)
        let projectContainers = containers.filter { $0.labels["capsule.project"] == document.projectName }
        let services = Dictionary(
            projectContainers.compactMap { container -> (String, ObservedServiceState)? in
                guard let service = container.labels["capsule.service"] else { return nil }
                return (service, ObservedServiceState(
                    service: service,
                    containerID: container.id,
                    containerName: container.id,
                    configHash: container.labels["capsule.config-hash"],
                    isRunning: container.runState == .running
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ObservedProjectState(
            services: services,
            volumeNames: Set(volumes.map(\.name)),
            networkNames: Set(networks.map(\.name))
        )
    }

    private func persistDesiredState(
        running: Bool,
        selectedServices: Set<String> = []
    ) async throws {
        let project = document.projectName
        var record = (try? store.loadProject(id: project)) ?? ProjectRecord(
            id: project,
            name: project,
            sourcePath: source.filePath ?? document.workingDirectory,
            createdAt: .now
        )
        // Re-opening from another file or with different frontend flags must
        // replace stale reopen metadata while preserving record identity/time.
        record.name = project
        record.sourcePath = source.filePath ?? document.workingDirectory
        record.environmentFilePaths = source.environmentFilePaths
        record.projectNameOverride = source.projectName
        try store.saveProject(record)
        try store.saveResolvedProject(document, projectID: project)
        let fullPlan = try planner.makePlan(for: document)
        let desiredContainers = Dictionary(
            uniqueKeysWithValues: fullPlan.steps.compactMap { step -> (String, (hash: String, name: String))? in
                guard case .ensureContainer(let service, let spec) = step,
                      let hash = spec.labels["capsule.config-hash"]
                else { return nil }
                return (service, (hash, spec.name ?? "\(project)-\(service)-1"))
            }
        )
        let hashes = desiredContainers.mapValues { $0.hash }
        let previous = try? await stateCoordinator.load(projectID: project)
        let services = Dictionary(uniqueKeysWithValues: desiredContainers.keys.map { service in
            let isSelected = selectedServices.isEmpty || selectedServices.contains(service)
            var state = previous?.services[service]
                ?? StoredServiceState(desiredRunning: running && isSelected)
            state.containerID = desiredContainers[service]?.name
            if isSelected {
                state.desiredRunning = running
            }
            if running && isSelected {
                state.stoppedByUser = false
                state.restart.scheduledFor = nil
                state.restart.scheduledContainerID = nil
            }
            return (service, state)
        })
        let initial = previous ?? StoredProjectState(
            revision: "",
            desiredRunning: running,
            serviceConfigHashes: [:]
        )
        let revision = try Self.revision(source: source, plan: fullPlan).rawValue
        try await stateCoordinator.update(projectID: project, initial: initial) { state in
            state.revision = revision
            state.serviceConfigHashes = hashes
            state.services = services
            state.desiredRunning = services.values.contains { $0.desiredRunning }
        }
    }

    private func stopTimeoutsByService() -> [String: Int?] {
        document.file.services.mapValues { service in
            guard let text = service.stopGracePeriod,
                  let duration = ComposeDuration.parse(text)
            else { return nil }
            let components = duration.components
            return max(0, Int(clamping: components.seconds) + (components.attoseconds > 0 ? 1 : 0))
        }
    }

    private struct RevisionInput: Codable {
        let source: ComposeSource
        let plan: ExecutionPlan
    }

    private static func revision(source: ComposeSource, plan: ExecutionPlan) throws -> ProjectRevision {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(RevisionInput(source: source, plan: plan))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ProjectRevision(rawValue: digest)
    }
}
