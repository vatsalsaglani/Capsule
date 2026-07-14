import ComposePlanner
import ComposeSpec
import ContainerClient
import Foundation
import Supervisor

public struct ProjectRevision: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct UpRequest: Codable, Sendable, Hashable {
    public var services: [String]
    public var build: Bool
    public var forceRecreate: Bool
    public var noDependencies: Bool

    public init(
        services: [String] = [],
        build: Bool = false,
        forceRecreate: Bool = false,
        noDependencies: Bool = false
    ) {
        self.services = services
        self.build = build
        self.forceRecreate = forceRecreate
        self.noDependencies = noDependencies
    }

    var planningOptions: PlanningOptions {
        PlanningOptions(
            services: services,
            forceRecreate: forceRecreate,
            noDependencies: noDependencies
        )
    }
}

public struct PreparedUp: Codable, Sendable, Hashable {
    public let source: ComposeSource
    public let document: ComposeDocument
    public let request: UpRequest
    public let revision: ProjectRevision
    public let plan: ExecutionPlan

    public init(
        source: ComposeSource,
        document: ComposeDocument,
        request: UpRequest,
        revision: ProjectRevision,
        plan: ExecutionPlan
    ) {
        self.source = source
        self.document = document
        self.request = request
        self.revision = revision
        self.plan = plan
    }
}

public struct DownRequest: Codable, Sendable, Hashable {
    public var removeVolumes: Bool
    public var removeOrphans: Bool

    public init(removeVolumes: Bool = false, removeOrphans: Bool = false) {
        self.removeVolumes = removeVolumes
        self.removeOrphans = removeOrphans
    }
}

/// Exact Capsule-owned resources affected by `compose down`. Volumes are
/// listed separately because the user chooses whether to preserve or delete
/// them at confirmation time.
public struct ComposeDownPreview: Codable, Sendable, Hashable {
    public let containers: [String]
    public let networks: [String]
    public let volumes: [String]

    public init(containers: [String], networks: [String], volumes: [String]) {
        self.containers = containers
        self.networks = networks
        self.volumes = volumes
    }
}

public struct ServiceSelection: Codable, Sendable, Hashable {
    public var services: [String]

    public init(_ services: [String] = []) {
        self.services = services
    }

    func contains(_ service: String) -> Bool {
        services.isEmpty || services.contains(service)
    }
}

public struct ProjectLogQuery: Codable, Sendable, Hashable {
    public var selection: ServiceSelection
    public var follow: Bool
    public var tail: Int?

    public init(selection: ServiceSelection = .init(), follow: Bool = false, tail: Int? = nil) {
        self.selection = selection
        self.follow = follow
        self.tail = tail
    }
}

public struct ProjectLogEntry: Sendable, Equatable {
    public let service: String
    public let index: Int
    public let containerID: String
    public let line: LogLine

    public init(service: String, index: Int, containerID: String, line: LogLine) {
        self.service = service
        self.index = index
        self.containerID = containerID
        self.line = line
    }
}

public struct ComposeServiceStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(service)-\(index)" }
    public let service: String
    public let index: Int
    public let containerID: String?
    public let runtimeState: ContainerRunState
    public let ports: [ContainerClient.PortMapping]
    public let configHash: String?
    public let health: HealthState?

    public init(
        service: String,
        index: Int,
        containerID: String?,
        runtimeState: ContainerRunState,
        ports: [ContainerClient.PortMapping] = [],
        configHash: String? = nil,
        health: HealthState? = nil
    ) {
        self.service = service
        self.index = index
        self.containerID = containerID
        self.runtimeState = runtimeState
        self.ports = ports
        self.configHash = configHash
        self.health = health
    }
}

public struct ComposeProjectStatus: Codable, Sendable, Equatable {
    public let project: String
    public let services: [ComposeServiceStatus]
    public let drift: DriftReport?

    public init(project: String, services: [ComposeServiceStatus], drift: DriftReport? = nil) {
        self.project = project
        self.services = services
        self.drift = drift
    }
}

/// Serializable structural graph for the Compose UI and future XPC client.
/// Edges point from a dependency to the service that waits for it, matching
/// the visual start flow from left to right.
public struct ComposeDependencyGraph: Codable, Sendable, Equatable, Hashable {
    public struct Edge: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: String {
            "\(dependency)->\(dependent):\(condition.rawValue)"
        }

        public let dependency: String
        public let dependent: String
        public let condition: DependsOn.Condition

        public init(
            dependency: String,
            dependent: String,
            condition: DependsOn.Condition
        ) {
            self.dependency = dependency
            self.dependent = dependent
            self.condition = condition
        }
    }

    public let services: [String]
    public let edges: [Edge]
    public let startLayers: [[String]]

    public init(services: [String], edges: [Edge], startLayers: [[String]]) {
        self.services = services
        self.edges = edges
        self.startLayers = startLayers
    }
}

public enum ComposeOperationKind: String, Codable, Sendable, Hashable {
    case up
    case down
    case start
    case stop
    case restart
    case build
    case pull
    case reconcile
}

public enum ComposeEvent: Codable, Sendable, Hashable {
    case operationStarted(id: UUID, kind: ComposeOperationKind)
    case stepStarted(PlanStep)
    case stepOutput(step: PlanStep, message: String)
    case stepCompleted(PlanStep)
    case stepFailed(PlanStep, message: String)
    case operationOutput(String)
    case warning(String)
    case operationCompleted(id: UUID, kind: ComposeOperationKind)
}

public enum ComposeRuntimeError: Error, Sendable, Equatable {
    case stalePreparedPlan(expected: ProjectRevision, actual: ProjectRevision)
    case missingContainer(service: String)
    case invalidHealthcheck(service: String, detail: String)
    case successfulExitStatusUnavailable(service: String)
    case unsupportedStep(String)
}

extension ComposeRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stalePreparedPlan(let expected, let actual):
            return "Compose plan is stale (prepared \(expected.rawValue), current \(actual.rawValue)); prepare and review it again."
        case .missingContainer(let service):
            return "No container exists for Compose service \(service)."
        case .invalidHealthcheck(let service, let detail):
            return "Service \(service) has an invalid healthcheck: \(detail)"
        case .successfulExitStatusUnavailable(let service):
            return "Cannot verify service_completed_successfully for \(service): container 1.1.x exposes stopped state but no exit status."
        case .unsupportedStep(let description):
            return "Unsupported Compose plan step: \(description)"
        }
    }
}
