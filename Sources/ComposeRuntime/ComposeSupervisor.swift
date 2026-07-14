import ComposePlanner
import ComposeSpec
import ContainerClient
import Foundation
import ProjectStore
import Supervisor

/// Frontend-resident v1 supervision. The caller owns the lifetime of
/// `run(events:onUpdate:)`; all durable state remains serializable so this
/// actor can move behind the future `capsuled` XPC boundary unchanged.
public actor ComposeSupervisor {
    public typealias UpdateSink = @Sendable (ComposeSupervisionSnapshot) async -> Void

    private let runtime: any ContainerRuntime
    private let store: ProjectStore
    private let stateCoordinator: ProjectStateCoordinator

    private var activeRunID: UUID?
    private var configuration = ComposeSupervisionConfiguration()
    private var updateSink: UpdateSink?
    private var runtimeAvailable = false
    private var observedByID: [String: ContainerSummary] = [:]
    private var projects: [String: ProjectContext] = [:]
    private var noticesByID: [String: SupervisionNotice] = [:]
    private var healthWorkers: [ServiceKey: WorkerRegistration] = [:]
    private var liveHealthWorkers: [ServiceKey: UUID] = [:]
    private var restartWorkers: [ServiceKey: WorkerRegistration] = [:]

    public init(
        runtime: any ContainerRuntime,
        store: ProjectStore = ProjectStore(),
        stateCoordinator: ProjectStateCoordinator? = nil
    ) {
        self.runtime = runtime
        self.store = store
        self.stateCoordinator = stateCoordinator ?? ProjectStateCoordinator(store: store)
    }

    /// Consumes the shared poller's event stream until cancelled. Only one
    /// run may be active; no hidden unstructured root task is created here.
    public func run(
        events: AsyncStream<RuntimeEvent>,
        configuration: ComposeSupervisionConfiguration = .init(),
        onUpdate: @escaping UpdateSink = { _ in }
    ) async throws {
        guard activeRunID == nil else { throw ComposeSupervisorError.alreadyRunning }
        let runID = UUID()
        activeRunID = runID
        self.configuration = configuration
        updateSink = onUpdate

        await withTaskGroup(of: Void.self) { group in
            for await event in events {
                guard !Task.isCancelled, activeRunID == runID else { break }
                do {
                    let workers = try await handle(event, runID: runID)
                    await publishSnapshot()
                    for worker in workers {
                        group.addTask { [weak self] in
                            await self?.run(worker: worker, runID: runID)
                        }
                    }

                    if case .snapshot = event, configuration.driftHandling == .autoHeal {
                        for projectID in projects.keys.sorted() {
                            try await reconcile(projectID: projectID, mode: .heal)
                        }
                        observedByID = Dictionary(
                            uniqueKeysWithValues: try await runtime.listContainers(all: true)
                                .map { ($0.id, $0) }
                        )
                        await publishSnapshot()
                    }
                } catch is CancellationError {
                    break
                } catch {
                    setNotice(.init(
                        code: "supervision-event-failed",
                        message: error.localizedDescription
                    ))
                    await publishSnapshot()
                }
            }
            group.cancelAll()
            await group.waitForAll()
        }

        guard activeRunID == runID else { return }
        healthWorkers.removeAll()
        liveHealthWorkers.removeAll()
        restartWorkers.removeAll()
        activeRunID = nil
        updateSink = nil
    }

    /// Serializable command channel used by AppCore today and an XPC adapter
    /// later. User intent is committed before runtime mutation.
    @discardableResult
    public func send(_ command: ComposeSupervisionCommand) async throws -> ComposeSupervisionSnapshot {
        try await loadPersistedProjects()
        observedByID = Dictionary(
            uniqueKeysWithValues: try await runtime.listContainers(all: true).map { ($0.id, $0) }
        )
        runtimeAvailable = true

        switch command {
        case .applyUserIntent(let projectID, let services, let intent):
            try await applyUserIntent(projectID: projectID, selection: services, intent: intent)
        case .reconcile(let projectID, let mode):
            try await reconcile(projectID: projectID, mode: mode)
        }

        observedByID = Dictionary(
            uniqueKeysWithValues: try await runtime.listContainers(all: true).map { ($0.id, $0) }
        )
        let snapshot = try await makeSnapshot()
        if let updateSink { await updateSink(snapshot) }
        return snapshot
    }

    private func handle(_ event: RuntimeEvent, runID: UUID) async throws -> [Worker] {
        switch event {
        case .snapshot(let containers):
            runtimeAvailable = true
            clearNotice(code: "runtime-unavailable")
            observedByID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
            try await loadPersistedProjects()
            return try await synchronizeWorkers(runID: runID)

        case .containerAdded(let container), .containerStateChanged(let container, _):
            observedByID[container.id] = container
            return try await synchronizeWorkers(runID: runID, projectID: container.labels["capsule.project"])

        case .containerRemoved(let id):
            let projectID = observedByID[id]?.labels["capsule.project"]
            observedByID[id] = nil
            return try await synchronizeWorkers(runID: runID, projectID: projectID)

        case .runtimeBecameUnavailable(let message):
            runtimeAvailable = false
            healthWorkers.removeAll()
            liveHealthWorkers.removeAll()
            restartWorkers.removeAll()
            setNotice(.init(code: "runtime-unavailable", message: message))
            return []

        case .runtimeBecameAvailable:
            runtimeAvailable = true
            clearNotice(code: "runtime-unavailable")
            // The poller contract publishes an authoritative snapshot next.
            return []
        }
    }

    private func loadPersistedProjects() async throws {
        let selected = configuration.projectIDs.map(Set.init)
        let records = try store.listProjects().filter { selected?.contains($0.id) ?? true }
        var loaded: [String: ProjectContext] = [:]

        for record in records {
            guard (try? await stateCoordinator.load(projectID: record.id)) != nil else {
                // Imported-but-never-started projects have no desired state and
                // therefore nothing to supervise yet.
                continue
            }
            do {
                let document = try store.loadResolvedProject(ComposeDocument.self, projectID: record.id)
                loaded[record.id] = try Self.makeContext(record: record, document: document)
                clearNotice(code: "project-attach-failed", projectID: record.id)
            } catch {
                setNotice(.init(
                    code: "project-attach-failed",
                    message: error.localizedDescription,
                    projectID: record.id
                ))
            }
        }

        let removed = Set(projects.keys).subtracting(loaded.keys)
        for projectID in removed {
            invalidateWorkers(projectID: projectID)
        }
        projects = loaded
    }

    private func synchronizeWorkers(runID: UUID, projectID: String? = nil) async throws -> [Worker] {
        let contexts = projectID.flatMap { projects[$0].map { [$0] } }
            ?? projects.values.sorted { $0.record.id < $1.record.id }
        var workers: [Worker] = []
        for context in contexts {
            workers.append(contentsOf: try await synchronize(context: context, runID: runID))
        }
        return workers
    }

    private func synchronize(context: ProjectContext, runID: UUID) async throws -> [Worker] {
        let projectID = context.record.id
        let previous = try await stateCoordinator.load(projectID: projectID)
        let observed = observedByID.values.filter { $0.labels["capsule.project"] == projectID }
        let byService = Dictionary(
            observed.compactMap { container -> (String, ContainerSummary)? in
                guard let service = container.labels["capsule.service"] else { return nil }
                return (service, container)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let state = try await stateCoordinator.update(projectID: projectID, initial: previous) { state in
            for (service, container) in byService {
                state.services[service]?.containerID = container.id
            }
        }

        var workers: [Worker] = []
        for definition in context.services.values.sorted(by: { $0.service < $1.service }) {
            let key = ServiceKey(projectID: projectID, service: definition.service)
            let serviceState = state.services[definition.service]
                ?? StoredServiceState(desiredRunning: false)
            let container = byService[definition.service]

            if let container,
               container.runState == .running,
               serviceState.desiredRunning,
               let healthcheck = definition.healthcheck {
                if healthWorkers[key]?.containerID != container.id {
                    let generation = UUID()
                    healthWorkers[key] = WorkerRegistration(generation: generation, containerID: container.id)
                    liveHealthWorkers[key] = nil
                    var resumedPlan = healthcheck
                    // A persisted observation for this exact container proves
                    // its one-time start period already elapsed in an earlier
                    // frontend process. Mark the restored value stale in the
                    // snapshot, but re-probe immediately instead of granting a
                    // fresh grace period every time Capsule relaunches.
                    if serviceState.containerID == container.id,
                       serviceState.healthObservation != nil {
                        resumedPlan.startPeriod = .zero
                    }
                    workers.append(.health(
                        key: key,
                        containerID: container.id,
                        plan: resumedPlan,
                        generation: generation
                    ))
                }
            } else {
                healthWorkers[key] = nil
                liveHealthWorkers[key] = nil
            }

            if let container, container.runState == .running {
                restartWorkers[key] = nil
                if serviceState.restart.scheduledFor != nil || serviceState.restart.lastError != nil {
                    try await stateCoordinator.update(projectID: projectID, initial: state) { state in
                        state.services[definition.service]?.restart.scheduledFor = nil
                        state.services[definition.service]?.restart.scheduledContainerID = nil
                        state.services[definition.service]?.restart.lastError = nil
                        state.services[definition.service]?.restart.limitation = nil
                    }
                }
            } else if let container,
                      container.runState == .stopped,
                      serviceState.desiredRunning,
                      !serviceState.stoppedByUser,
                      restartWorkers[key] == nil,
                      let worker = try await prepareRestart(
                        key: key,
                        containerID: container.id,
                        definition: definition,
                        state: state,
                        runID: runID
                      ) {
                workers.append(worker)
            }
        }
        return workers
    }

    private func prepareRestart(
        key: ServiceKey,
        containerID: String,
        definition: ServiceDefinition,
        state: StoredProjectState,
        runID: UUID
    ) async throws -> Worker? {
        guard definition.restartPolicy != .never else { return nil }
        let serviceState = state.services[key.service] ?? StoredServiceState(desiredRunning: true)

        if let scheduledFor = serviceState.restart.scheduledFor,
           serviceState.restart.scheduledContainerID == containerID {
            let generation = UUID()
            restartWorkers[key] = WorkerRegistration(generation: generation, containerID: containerID)
            return .restart(
                key: key,
                containerID: containerID,
                scheduledFor: scheduledFor,
                generation: generation
            )
        }

        let coordinator = RestartCoordinator(
            services: [.init(
                service: key.service,
                containerID: containerID,
                policy: definition.restartPolicy
            )],
            snapshot: SupervisorSnapshot(services: [
                key.service: ServiceSupervisionState(
                    attempts: serviceState.restart.attempts,
                    stoppedByUser: serviceState.stoppedByUser
                ),
            ])
        )
        let decision = await coordinator.containerStopped(containerID: containerID, exitCode: nil)
        switch decision {
        case .none:
            return nil
        case .exitStatusUnavailable:
            try await stateCoordinator.update(projectID: key.projectID, initial: state) { state in
                state.services[key.service]?.restart.limitation = .exitStatusUnavailable
                state.services[key.service]?.restart.scheduledFor = nil
                state.services[key.service]?.restart.scheduledContainerID = nil
            }
            setNotice(.init(
                code: "exit-status-unavailable",
                message: "Restart policy on-failure is paused because container 1.1.x does not expose exit status.",
                projectID: key.projectID,
                service: key.service
            ))
            return nil
        case .schedule(_, _, let delay):
            let scheduledFor = Date().addingTimeInterval(Self.timeInterval(delay))
            let snapshot = await coordinator.snapshot()
            let attempts = snapshot.services[key.service]?.attempts ?? serviceState.restart.attempts + 1
            try await stateCoordinator.update(projectID: key.projectID, initial: state) { state in
                state.services[key.service]?.restart.attempts = attempts
                state.services[key.service]?.restart.scheduledFor = scheduledFor
                state.services[key.service]?.restart.scheduledContainerID = containerID
                state.services[key.service]?.restart.lastError = nil
                state.services[key.service]?.restart.limitation = nil
            }
            let generation = UUID()
            restartWorkers[key] = WorkerRegistration(generation: generation, containerID: containerID)
            return .restart(
                key: key,
                containerID: containerID,
                scheduledFor: scheduledFor,
                generation: generation
            )
        }
    }

    private func run(worker: Worker, runID: UUID) async {
        switch worker {
        case .health(let key, let containerID, let plan, let generation):
            do {
                try await HealthMonitor(runtime: runtime).run(
                    containerID: containerID,
                    plan: plan,
                    onObservation: { [weak self] observation in
                        guard let self else { return }
                        try await self.recordHealth(
                            observation,
                            key: key,
                            containerID: containerID,
                            generation: generation,
                            runID: runID
                        )
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                await recordWorkerFailure(error, key: key, code: "health-monitor-failed")
            }

        case .restart(let key, let containerID, let scheduledFor, let generation):
            await restartLoop(
                key: key,
                containerID: containerID,
                scheduledFor: scheduledFor,
                generation: generation,
                runID: runID
            )
        }
    }

    private func recordHealth(
        _ observation: HealthProbeObservation,
        key: ServiceKey,
        containerID: String,
        generation: UUID,
        runID: UUID
    ) async throws {
        guard activeRunID == runID,
              healthWorkers[key] == WorkerRegistration(generation: generation, containerID: containerID)
        else { throw CancellationError() }
        let current = try await stateCoordinator.load(projectID: key.projectID)
        try await stateCoordinator.update(projectID: key.projectID, initial: current) { state in
            var service = state.services[key.service]
                ?? StoredServiceState(containerID: containerID, desiredRunning: true)
            service.containerID = containerID
            service.healthObservation = StoredHealthObservation(
                state: StoredHealthState(rawValue: observation.state.rawValue) ?? .starting,
                attempt: observation.attempt,
                output: observation.output,
                observedAt: .now
            )
            state.services[key.service] = service
        }
        liveHealthWorkers[key] = generation
        clearNotice(code: "health-monitor-failed", projectID: key.projectID, service: key.service)
        await publishSnapshot()
    }

    private func restartLoop(
        key: ServiceKey,
        containerID: String,
        scheduledFor initialDeadline: Date,
        generation: UUID,
        runID: UUID
    ) async {
        var deadline = initialDeadline
        while activeRunID == runID,
              restartWorkers[key] == WorkerRegistration(generation: generation, containerID: containerID) {
            do {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                try await Task.sleep(for: .milliseconds(Int64(remaining * 1_000)))
                try Task.checkCancellation()
                guard activeRunID == runID,
                      restartWorkers[key] == WorkerRegistration(generation: generation, containerID: containerID)
                else { return }
                let state = try await stateCoordinator.load(projectID: key.projectID)
                guard let service = state.services[key.service],
                      service.desiredRunning,
                      !service.stoppedByUser,
                      service.containerID == containerID
                else {
                    restartWorkers[key] = nil
                    return
                }

                do {
                    try await runtime.startContainer(id: containerID)
                    do {
                        try await refreshManagedHosts(projectID: key.projectID)
                        clearNotice(
                            code: "hosts-refresh-failed",
                            projectID: key.projectID,
                            service: key.service
                        )
                    } catch {
                        // The container is running, so do not turn a discovery
                        // refresh failure into another start attempt. Surface
                        // it as drift requiring attention and retry on the next
                        // supervised restart/reconcile.
                        setNotice(.init(
                            code: "hosts-refresh-failed",
                            message: error.localizedDescription,
                            projectID: key.projectID,
                            service: key.service
                        ))
                    }
                    try await stateCoordinator.update(projectID: key.projectID, initial: state) { state in
                        state.services[key.service]?.restart.scheduledFor = nil
                        state.services[key.service]?.restart.scheduledContainerID = nil
                        state.services[key.service]?.restart.lastError = nil
                        state.services[key.service]?.restart.limitation = nil
                    }
                    restartWorkers[key] = nil
                    clearNotice(code: "restart-failed", projectID: key.projectID, service: key.service)
                    await publishSnapshot()
                    return
                } catch {
                    let nextAttempt = service.restart.attempts + 1
                    let delay = RestartPolicy.backoffDelay(attempt: nextAttempt)
                    let nextDeadline = Date().addingTimeInterval(Self.timeInterval(delay))
                    let errorMessage = error.localizedDescription
                    deadline = nextDeadline
                    try await stateCoordinator.update(projectID: key.projectID, initial: state) { state in
                        state.services[key.service]?.restart.attempts = nextAttempt
                        state.services[key.service]?.restart.scheduledFor = nextDeadline
                        state.services[key.service]?.restart.scheduledContainerID = containerID
                        state.services[key.service]?.restart.lastError = errorMessage
                    }
                    setNotice(.init(
                        code: "restart-failed",
                        message: errorMessage,
                        projectID: key.projectID,
                        service: key.service
                    ))
                    if nextAttempt >= 10 {
                        setNotice(.init(
                            code: "restart-storm",
                            message: "Repeated restart failures are being rate-limited with capped exponential backoff.",
                            projectID: key.projectID,
                            service: key.service
                        ))
                    }
                    await publishSnapshot()
                }
            } catch is CancellationError {
                return
            } catch {
                await recordWorkerFailure(error, key: key, code: "restart-failed")
                return
            }
        }
    }

    private func applyUserIntent(
        projectID: String,
        selection: ServiceSelection,
        intent: UserServiceIntent
    ) async throws {
        guard projects[projectID] != nil else { throw ComposeSupervisorError.projectNotFound(projectID) }
        let containers = observedByID.values.filter {
            $0.labels["capsule.project"] == projectID
                && selection.contains($0.labels["capsule.service"] ?? "")
        }
        let initial = try await stateCoordinator.load(projectID: projectID)
        let selectedServices = Set(containers.compactMap { $0.labels["capsule.service"] })
        try await stateCoordinator.update(projectID: projectID, initial: initial) { state in
            for serviceName in selectedServices {
                guard var service = state.services[serviceName] else { continue }
                switch intent {
                case .start:
                    service.desiredRunning = true
                    service.stoppedByUser = false
                case .stop:
                    service.desiredRunning = false
                    service.stoppedByUser = true
                case .restart:
                    service.desiredRunning = true
                    service.stoppedByUser = true
                }
                state.services[serviceName] = service
            }
            state.desiredRunning = state.services.values.contains { $0.desiredRunning }
        }

        for container in containers.sorted(by: { $0.id < $1.id }) {
            switch intent {
            case .start:
                try await runtime.startContainer(id: container.id)
            case .stop:
                try await runtime.stopContainer(id: container.id, timeoutSeconds: nil)
            case .restart:
                if container.runState == .running {
                    try await runtime.stopContainer(id: container.id, timeoutSeconds: nil)
                }
                try await runtime.startContainer(id: container.id)
            }
        }

        if intent == .restart {
            let current = try await stateCoordinator.load(projectID: projectID)
            try await stateCoordinator.update(projectID: projectID, initial: current) { state in
                for service in selectedServices {
                    state.services[service]?.stoppedByUser = false
                }
            }
        }
    }

    private func reconcile(projectID: String, mode: ReconcileMode) async throws {
        guard let context = projects[projectID] else {
            throw ComposeSupervisorError.projectNotFound(projectID)
        }
        guard mode == .heal else { return }
        let snapshot = try await makeProjectSnapshot(context)
        guard !snapshot.drift.isInSync else { return }
        let project = makeProject(context)
        let state = try await stateCoordinator.load(projectID: projectID)

        let recreate = Set(snapshot.drift.findings.compactMap { finding in
            finding.kind == .missing || finding.kind == .configurationChanged
                ? finding.service
                : nil
        })
        for service in recreate.sorted() {
            let force = snapshot.drift.findings.contains {
                $0.service == service && $0.kind == .configurationChanged
            }
            let prepared = try await project.prepareUp(UpRequest(
                services: [service],
                forceRecreate: force,
                noDependencies: true
            ))
            for try await _ in try await project.up(prepared) {}
        }

        for finding in snapshot.drift.findings where finding.kind == .unexpectedState {
            let selection = ServiceSelection([finding.service])
            if state.services[finding.service]?.desiredRunning == true {
                for try await _ in try await project.start(selection) {}
            } else {
                for try await _ in try await project.stop(selection) {}
            }
        }
        // Orphans remain visible. Automatic deletion is intentionally reserved
        // for the explicit `compose down --remove-orphans` confirmation path.
    }

    /// Rebuilds the managed hosts block after a supervised restart. The
    /// runtime can assign a new address on each start, so every currently
    /// running project container is both a target and an eligible peer.
    private func refreshManagedHosts(projectID: String) async throws {
        guard let context = projects[projectID], !context.hostTargets.isEmpty else { return }
        let current = try await runtime.listContainers(all: true)
        observedByID.merge(
            current.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let runningIDs = Set(current.filter { $0.runState == .running }.map(\.id))
        let targets = context.hostTargets.compactMap { target -> ServiceHostTarget? in
            guard runningIDs.contains(target.containerReference) else { return nil }
            return ServiceHostTarget(
                service: target.service,
                containerReference: target.containerReference,
                peers: target.peers.filter { runningIDs.contains($0.containerReference) }
            )
        }
        guard !targets.isEmpty else { return }
        try await ComposeExecutor.refreshHosts(
            targets: targets,
            runtime: runtime,
            output: { _ in }
        )
    }

    private func makeProject(_ context: ProjectContext) -> ComposeProject {
        let document = context.document
        let source = ComposeSource(
            yaml: "",
            projectName: document.projectName,
            fallbackName: context.record.name,
            workingDirectory: document.workingDirectory,
            filePath: context.record.sourcePath,
            environmentFilePaths: context.record.environmentFilePaths
        )
        return ComposeProject(
            runtime: runtime,
            store: store,
            stateCoordinator: stateCoordinator,
            source: source,
            document: document
        )
    }

    private func publishSnapshot() async {
        guard let updateSink else { return }
        do {
            await updateSink(try await makeSnapshot())
        } catch {
            setNotice(.init(code: "snapshot-failed", message: error.localizedDescription))
        }
    }

    private func makeSnapshot() async throws -> ComposeSupervisionSnapshot {
        var projectSnapshots: [ProjectSupervisionSnapshot] = []
        for context in projects.values.sorted(by: { $0.record.id < $1.record.id }) {
            projectSnapshots.append(try await makeProjectSnapshot(context))
        }
        return ComposeSupervisionSnapshot(
            runID: activeRunID,
            runtimeAvailable: runtimeAvailable,
            projects: projectSnapshots,
            notices: noticesByID.values
                .filter { $0.projectID == nil }
                .sorted { $0.id < $1.id }
        )
    }

    private func makeProjectSnapshot(_ context: ProjectContext) async throws -> ProjectSupervisionSnapshot {
        let projectID = context.record.id
        let state = try await stateCoordinator.load(projectID: projectID)
        let observed = observedByID.values.filter { $0.labels["capsule.project"] == projectID }
        let byService = Dictionary(
            observed.compactMap { container -> (String, ContainerSummary)? in
                guard let service = container.labels["capsule.service"] else { return nil }
                return (service, container)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let desired = context.services.values.map { definition in
            DesiredServiceInstance(
                service: definition.service,
                index: definition.index,
                containerName: definition.containerName,
                configHash: definition.configHash,
                shouldRun: state.services[definition.service]?.desiredRunning
                    ?? state.desiredRunning
            )
        }
        let drift = DriftReconciler.report(project: projectID, desired: desired, observed: observed)
        let services = context.services.values.sorted(by: { $0.service < $1.service }).map { definition in
            let key = ServiceKey(projectID: projectID, service: definition.service)
            let stored = state.services[definition.service]
                ?? StoredServiceState(desiredRunning: false)
            let container = byService[definition.service]
            let health = stored.healthObservation.map { observation in
                ServiceHealthSnapshot(
                    state: HealthState(rawValue: observation.state.rawValue) ?? .starting,
                    attempt: observation.attempt,
                    output: observation.output,
                    observedAt: observation.observedAt,
                    isLive: liveHealthWorkers[key] == healthWorkers[key]?.generation
                )
            }
            return ServiceSupervisionSnapshot(
                service: definition.service,
                index: definition.index,
                containerID: container?.id ?? stored.containerID,
                runtimeState: container?.runState ?? .unknown,
                desiredRunning: stored.desiredRunning,
                stoppedByUser: stored.stoppedByUser,
                health: health,
                restart: ServiceRestartSnapshot(
                    policy: definition.restartPolicy,
                    attempts: stored.restart.attempts,
                    scheduledFor: stored.restart.scheduledFor,
                    lastError: stored.restart.lastError,
                    limitation: stored.restart.limitation.map(Self.restartLimitation)
                )
            )
        }
        return ProjectSupervisionSnapshot(
            projectID: projectID,
            services: services,
            drift: drift,
            dependencyGraph: context.graph,
            notices: noticesByID.values
                .filter { $0.projectID == projectID }
                .sorted { $0.id < $1.id }
        )
    }

    private func recordWorkerFailure(_ error: Error, key: ServiceKey, code: String) async {
        setNotice(.init(
            code: code,
            message: error.localizedDescription,
            projectID: key.projectID,
            service: key.service
        ))
        await publishSnapshot()
    }

    private func invalidateWorkers(projectID: String) {
        healthWorkers = healthWorkers.filter { $0.key.projectID != projectID }
        liveHealthWorkers = liveHealthWorkers.filter { $0.key.projectID != projectID }
        restartWorkers = restartWorkers.filter { $0.key.projectID != projectID }
    }

    private func setNotice(_ notice: SupervisionNotice) {
        noticesByID[notice.id] = notice
    }

    private func clearNotice(code: String, projectID: String? = nil, service: String? = nil) {
        let id = [projectID, service, code].compactMap { $0 }.joined(separator: ":")
        noticesByID[id] = nil
    }

    private static func makeContext(record: ProjectRecord, document: ComposeDocument) throws -> ProjectContext {
        let plan = try Planner().makePlan(for: document)
        let specs = Dictionary(
            uniqueKeysWithValues: plan.steps.compactMap { step -> (String, RunSpec)? in
                guard case .ensureContainer(let service, let spec) = step else { return nil }
                return (service, spec)
            }
        )
        var services: [String: ServiceDefinition] = [:]
        for (service, composeService) in document.file.services {
            guard let spec = specs[service] else { continue }
            services[service] = ServiceDefinition(
                service: service,
                index: Int(spec.labels["capsule.index"] ?? "1") ?? 1,
                containerName: spec.name ?? "\(document.projectName)-\(service)-1",
                configHash: spec.labels["capsule.config-hash"] ?? "",
                restartPolicy: restartPolicy(composeService.restart),
                healthcheck: try composeService.healthcheck.flatMap {
                    try ComposeExecutor.healthcheckPlan(for: $0, service: service)
                }
            )
        }
        return ProjectContext(
            record: record,
            document: document,
            services: services,
            graph: try dependencyGraph(document),
            hostTargets: plan.steps.compactMap { step -> [ServiceHostTarget]? in
                guard case .refreshHosts(let targets) = step else { return nil }
                return targets
            }.last ?? []
        )
    }

    private static func dependencyGraph(_ document: ComposeDocument) throws -> ComposeDependencyGraph {
        let dependencies = document.file.services.mapValues {
            Set($0.dependsOn?.requirements.keys.map { $0 } ?? [])
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

    private static func restartPolicy(_ mode: RestartMode?) -> RestartPolicy {
        switch mode {
        case .none, .some(.no): .never
        case .some(.always): .always
        case .some(.unlessStopped): .unlessStopped
        case .some(.onFailure(let maxRetries)): .onFailure(maxRetries: maxRetries)
        }
    }

    private static func restartLimitation(_ limitation: StoredRestartLimitation) -> RestartLimitation {
        switch limitation {
        case .exitStatusUnavailable: .exitStatusUnavailable
        case .retryBudgetExhausted: .retryBudgetExhausted
        }
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct ServiceDefinition: Sendable {
    let service: String
    let index: Int
    let containerName: String
    let configHash: String
    let restartPolicy: RestartPolicy
    let healthcheck: HealthcheckPlan?
}

private struct ProjectContext: Sendable {
    let record: ProjectRecord
    let document: ComposeDocument
    let services: [String: ServiceDefinition]
    let graph: ComposeDependencyGraph
    let hostTargets: [ServiceHostTarget]
}

private struct ServiceKey: Sendable, Hashable {
    let projectID: String
    let service: String
}

private struct WorkerRegistration: Sendable, Equatable {
    let generation: UUID
    let containerID: String
}

private enum Worker: Sendable {
    case health(
        key: ServiceKey,
        containerID: String,
        plan: HealthcheckPlan,
        generation: UUID
    )
    case restart(
        key: ServiceKey,
        containerID: String,
        scheduledFor: Date,
        generation: UUID
    )
}
