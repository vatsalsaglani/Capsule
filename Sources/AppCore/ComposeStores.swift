import ComposeRuntime
import ComposeSpec
import ContainerClient
import Foundation
import Observation
import ProjectStore
import Supervisor

public struct ComposeProjectItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let fileURL: URL?
    public let recordedSourcePath: String?
    public let projectNameOverride: String?
    public let environmentFileURLs: [URL]

    public var sourceAvailable: Bool { fileURL != nil }

    public var sourceUnavailableDescription: String? {
        guard fileURL == nil else { return nil }
        if let recordedSourcePath {
            return "Compose source unavailable at \(recordedSourcePath)"
        }
        return "Compose source was not recorded; re-import the project file to manage it."
    }

    public init(
        id: String,
        name: String,
        fileURL: URL?,
        recordedSourcePath: String? = nil,
        projectNameOverride: String? = nil,
        environmentFileURLs: [URL] = []
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.recordedSourcePath = recordedSourcePath ?? fileURL?.path
        self.projectNameOverride = projectNameOverride
        self.environmentFileURLs = environmentFileURLs
    }
}

@MainActor
@Observable
public final class ComposeProjectsStore {
    public enum Phase: Equatable { case loading, loaded([ComposeProjectItem]), failed(String) }
    public private(set) var phase: Phase = .loading
    public private(set) var discoveryWarning: String?
    private let engine: ComposeEngine
    private let store: ProjectStore
    private let runtime: any ContainerRuntime
    private let supervisor: ComposeSupervisor?
    private let supervisionStore: ComposeSupervisionStore

    public init(
        runtime: any ContainerRuntime,
        store: ProjectStore = ProjectStore(),
        stateCoordinator: ProjectStateCoordinator? = nil,
        supervisor: ComposeSupervisor? = nil,
        supervisionStore: ComposeSupervisionStore = ComposeSupervisionStore()
    ) {
        self.runtime = runtime
        self.engine = ComposeEngine(
            runtime: runtime,
            store: store,
            stateCoordinator: stateCoordinator
        )
        self.store = store
        self.supervisor = supervisor
        self.supervisionStore = supervisionStore
    }

    public func refresh() async {
        let records: [ProjectRecord]
        do {
            records = try store.listProjects()
        } catch {
            phase = .failed(Self.message(error))
            return
        }

        var itemsByID = Dictionary(uniqueKeysWithValues: records.map { record in
            let file = Self.composeFile(at: URL(fileURLWithPath: record.sourcePath))
            return (record.id, ComposeProjectItem(
                id: record.id,
                name: record.name,
                fileURL: file,
                recordedSourcePath: record.sourcePath,
                projectNameOverride: record.projectNameOverride,
                environmentFileURLs: record.environmentFilePaths.map(URL.init(fileURLWithPath:))
            ))
        })
        // Disk is authoritative for the project list. Publish it before any
        // runtime call so a transient runtime failure can never hide records.
        phase = .loaded(itemsByID.values.sorted { $0.name < $1.name })
        discoveryWarning = nil

        var runtimeProjects: Set<String> = []
        var discoveryFailures: [String] = []
        do {
            runtimeProjects.formUnion(try await runtime.listContainers(all: true).compactMap {
                $0.labels["capsule.project"]
            })
        } catch {
            discoveryFailures.append("containers: \(Self.message(error))")
        }
        do {
            runtimeProjects.formUnion(try await runtime.listVolumes().compactMap {
                $0.labels["capsule.project"]
            })
        } catch {
            discoveryFailures.append("volumes: \(Self.message(error))")
        }
        do {
            runtimeProjects.formUnion(try await runtime.listNetworks().compactMap {
                $0.labels["capsule.project"]
            })
        } catch {
            discoveryFailures.append("networks: \(Self.message(error))")
        }
        for project in runtimeProjects where itemsByID[project] == nil {
            itemsByID[project] = ComposeProjectItem(id: project, name: project, fileURL: nil)
        }
        discoveryWarning = discoveryFailures.isEmpty
            ? nil
            : "Runtime project discovery was incomplete (\(discoveryFailures.joined(separator: "; "))). Saved projects remain available."
        phase = .loaded(itemsByID.values.sorted { $0.name < $1.name })
    }

    @discardableResult
    public func importFile(_ url: URL) async throws -> ComposeProjectItem {
        let source = try ComposeSourceLoader.load(fileURL: url)
        let project = try await engine.open(source)
        let document = await project.configuration()
        let item = ComposeProjectItem(
            id: document.projectName,
            name: document.projectName,
            fileURL: url.standardizedFileURL
        )
        try store.saveProject(ProjectRecord(
            id: item.id,
            name: item.name,
            sourcePath: url.standardizedFileURL.path,
            createdAt: .now
        ))
        try store.saveResolvedProject(document, projectID: item.id)
        var items: [ComposeProjectItem]
        if case .loaded(let current) = phase { items = current.filter { $0.id != item.id } } else { items = [] }
        items.append(item)
        phase = .loaded(items.sorted { $0.name < $1.name })
        return item
    }

    public func makeDetailStore(for item: ComposeProjectItem) -> ComposeProjectDetailStore {
        ComposeProjectDetailStore(
            engine: engine,
            item: item,
            supervisor: supervisor,
            supervisionStore: supervisionStore
        )
    }

    private static func composeFile(at source: URL) -> URL? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return source
        }
        return ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
            .map { source.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

public struct ComposeLogDisplay: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let service: String
    public let text: String
    public init(service: String, text: String) { self.id = UUID(); self.service = service; self.text = text }
}

@MainActor
@Observable
public final class ComposeProjectDetailStore {
    public enum Phase: Equatable { case loading, loaded, failed(String) }
    public private(set) var phase: Phase = .loading
    public private(set) var services: [ComposeServiceStatus] = []
    public private(set) var drift: DriftReport?
    public private(set) var dependencyGraph: ComposeDependencyGraph?
    public private(set) var planLines: [String] = []
    public private(set) var configReport = ""
    public private(set) var resolvedConfiguration = ""
    public private(set) var operationError: String?
    public private(set) var operationLines: [String] = []
    public private(set) var logs: [ComposeLogDisplay] = []
    public private(set) var logError: String?
    public private(set) var isFollowingLogs = false
    public private(set) var downPreview: ComposeDownPreview?
    public private(set) var isOperating = false
    public let item: ComposeProjectItem
    public var canOperate: Bool { item.sourceAvailable && project != nil && phase == .loaded }
    public var supervision: ProjectSupervisionSnapshot? { supervisionStore.project(item.id) }

    private let engine: ComposeEngine
    private let supervisor: ComposeSupervisor?
    private let supervisionStore: ComposeSupervisionStore
    @ObservationIgnored private var project: ComposeProject?
    @ObservationIgnored private var prepared: PreparedUp?
    @ObservationIgnored private nonisolated(unsafe) var logTask: Task<Void, Never>?
    @ObservationIgnored private var logsRequested = false
    @ObservationIgnored private var logGeneration = UUID()

    init(
        engine: ComposeEngine,
        item: ComposeProjectItem,
        supervisor: ComposeSupervisor?,
        supervisionStore: ComposeSupervisionStore
    ) {
        self.engine = engine
        self.item = item
        self.supervisor = supervisor
        self.supervisionStore = supervisionStore
    }
    deinit { logTask?.cancel() }

    public func load() async {
        do {
            guard let fileURL = item.fileURL else {
                phase = .failed(item.sourceUnavailableDescription ?? "Compose source unavailable.")
                return
            }
            let source = try ComposeSourceLoader.load(
                fileURL: fileURL,
                projectName: item.projectNameOverride,
                environmentFileURL: item.environmentFileURLs.first
            )
            let project = try await engine.open(source)
            self.project = project
            let configuration = await project.configuration()
            resolvedConfiguration = try ComposePresentation.resolvedConfiguration(configuration)
            configReport = "\(ComposePresentation.serviceDiscoveryExplanation)\n\n\(configuration.support.rendered)"
            let status = try await project.status()
            services = status.services
            drift = status.drift
            dependencyGraph = try await project.dependencyGraph()
            if let supervisor {
                _ = try await supervisor.send(.reconcile(projectID: item.id, mode: .reportOnly))
            }
            phase = .loaded
            if logsRequested { _ = beginLogs(follow: true) }
        } catch { phase = .failed(Self.message(error)) }
    }

    @discardableResult
    public func prepareUp(build: Bool = false, forceRecreate: Bool = false) async -> Bool {
        guard item.sourceAvailable, let project else {
            prepared = nil
            planLines = []
            return false
        }
        do {
            let prepared = try await project.prepareUp(UpRequest(build: build, forceRecreate: forceRecreate))
            self.prepared = prepared
            planLines = prepared.plan.rendered.split(separator: "\n").map(String.init)
            return true
        } catch {
            self.prepared = nil
            planLines = []
            phase = .failed(Self.message(error))
            return false
        }
    }

    public func confirmUp() async { guard let project, let prepared else { return }; await run { try await project.up(prepared) }; self.prepared = nil; planLines = [] }
    public func down(removeVolumes: Bool) async { guard let project else { return }; await run { try await project.down(DownRequest(removeVolumes: removeVolumes)) } }
    public func restart() async { guard let project else { return }; await run { try await project.restart() } }

    public func reconcile(heal: Bool) async {
        guard let supervisor else { return }
        isOperating = true
        operationError = nil
        defer { isOperating = false }
        do {
            _ = try await supervisor.send(.reconcile(
                projectID: item.id,
                mode: heal ? .heal : .reportOnly
            ))
            if let project {
                let status = try await project.status()
                services = status.services
                drift = status.drift
            }
        } catch {
            operationError = Self.message(error)
        }
    }

    @discardableResult
    public func prepareDownPreview() async -> Bool {
        guard let project else {
            downPreview = nil
            return false
        }
        do {
            downPreview = try await project.downPreview()
            return true
        } catch {
            downPreview = nil
            operationError = Self.message(error)
            return false
        }
    }

    @discardableResult
    public func startLogs(follow: Bool = true) -> Task<Void, Never>? {
        logsRequested = true
        return beginLogs(follow: follow)
    }

    @discardableResult
    private func beginLogs(follow: Bool) -> Task<Void, Never>? {
        guard let project else { return nil }
        logTask?.cancel()
        let generation = UUID()
        logGeneration = generation
        logs = []
        logError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            self.isFollowingLogs = follow
            defer {
                if self.logGeneration == generation {
                    self.isFollowingLogs = false
                }
            }
            do {
                let stream = try await project.logs(ProjectLogQuery(follow: follow, tail: 200))
                for try await entry in stream {
                    guard !Task.isCancelled, self.logGeneration == generation else { return }
                    self.logs.append(ComposeLogDisplay(service: entry.service, text: entry.line.text))
                    if self.logs.count > 2_000 {
                        self.logs.removeFirst(self.logs.count - 2_000)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if self.logGeneration == generation {
                    self.logError = Self.message(error)
                }
            }
        }
        logTask = task
        return task
    }
    public func stopLogs() {
        logsRequested = false
        logGeneration = UUID()
        logTask?.cancel()
        logTask = nil
        isFollowingLogs = false
    }

    public func clearLogs() {
        logs = []
        logError = nil
    }

    public func clearOperationLines() {
        operationLines = []
    }

    private func run(_ operation: () async throws -> AsyncThrowingStream<ComposeEvent, Error>) async {
        isOperating = true; operationLines = []; operationError = nil
        defer { isOperating = false }
        do {
            for try await event in try await operation() {
                if case .stepStarted(let step) = event { operationLines.append("→ \(step.description)") }
                if case .operationOutput(let line) = event { operationLines.append(line) }
                if case .stepOutput(_, let line) = event { operationLines.append(line) }
                if case .stepCompleted(let step) = event { operationLines.append("✓ \(step.description)") }
                if case .stepFailed(let step, let message) = event { operationLines.append("\(step.description): \(message)") }
            }
            if let project {
                let status = try await project.status()
                services = status.services
                drift = status.drift
            }
        } catch {
            let message = Self.message(error)
            operationLines.append(message)
            operationError = message
        }
    }

    public func dismissOperationError() { operationError = nil }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
