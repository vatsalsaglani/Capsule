import ComposeSpec
import ContainerClient
import Foundation
import Supervisor

public enum DriftHandling: String, Codable, Sendable, Equatable {
    case reportOnly
    case autoHeal
}

public struct ComposeSupervisionConfiguration: Codable, Sendable, Equatable {
    /// `nil` attaches every persisted project.
    public var projectIDs: [String]?
    public var driftHandling: DriftHandling

    public init(projectIDs: [String]? = nil, driftHandling: DriftHandling = .reportOnly) {
        self.projectIDs = projectIDs
        self.driftHandling = driftHandling
    }
}

public enum ReconcileMode: String, Codable, Sendable, Equatable {
    case reportOnly
    case heal
}

public enum UserServiceIntent: String, Codable, Sendable, Equatable {
    case start
    case stop
    case restart
}

public enum ComposeSupervisionCommand: Codable, Sendable, Equatable {
    case applyUserIntent(
        projectID: String,
        services: ServiceSelection,
        intent: UserServiceIntent
    )
    case reconcile(projectID: String, mode: ReconcileMode)
}

public enum RestartLimitation: String, Codable, Sendable, Equatable {
    case exitStatusUnavailable
    case retryBudgetExhausted
}

public struct ServiceHealthSnapshot: Codable, Sendable, Equatable {
    public let state: HealthState
    public let attempt: Int
    public let output: String
    public let observedAt: Date
    public let isLive: Bool

    public init(
        state: HealthState,
        attempt: Int,
        output: String,
        observedAt: Date,
        isLive: Bool
    ) {
        self.state = state
        self.attempt = attempt
        self.output = output
        self.observedAt = observedAt
        self.isLive = isLive
    }
}

public struct ServiceRestartSnapshot: Codable, Sendable, Equatable {
    public let policy: RestartPolicy
    public let attempts: Int
    public let scheduledFor: Date?
    public let lastError: String?
    public let limitation: RestartLimitation?

    public init(
        policy: RestartPolicy,
        attempts: Int,
        scheduledFor: Date?,
        lastError: String?,
        limitation: RestartLimitation?
    ) {
        self.policy = policy
        self.attempts = attempts
        self.scheduledFor = scheduledFor
        self.lastError = lastError
        self.limitation = limitation
    }
}

public struct ServiceSupervisionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(service)-\(index)" }

    public let service: String
    public let index: Int
    public let containerID: String?
    public let runtimeState: ContainerRunState
    public let desiredRunning: Bool
    public let stoppedByUser: Bool
    public let health: ServiceHealthSnapshot?
    public let restart: ServiceRestartSnapshot

    public init(
        service: String,
        index: Int,
        containerID: String?,
        runtimeState: ContainerRunState,
        desiredRunning: Bool,
        stoppedByUser: Bool,
        health: ServiceHealthSnapshot?,
        restart: ServiceRestartSnapshot
    ) {
        self.service = service
        self.index = index
        self.containerID = containerID
        self.runtimeState = runtimeState
        self.desiredRunning = desiredRunning
        self.stoppedByUser = stoppedByUser
        self.health = health
        self.restart = restart
    }
}

public struct SupervisionNotice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { [projectID, service, code].compactMap { $0 }.joined(separator: ":") }

    public let code: String
    public let message: String
    public let projectID: String?
    public let service: String?

    public init(code: String, message: String, projectID: String? = nil, service: String? = nil) {
        self.code = code
        self.message = message
        self.projectID = projectID
        self.service = service
    }
}

public struct ProjectSupervisionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { projectID }

    public let projectID: String
    public let services: [ServiceSupervisionSnapshot]
    public let drift: DriftReport
    public let dependencyGraph: ComposeDependencyGraph
    public let notices: [SupervisionNotice]

    public init(
        projectID: String,
        services: [ServiceSupervisionSnapshot],
        drift: DriftReport,
        dependencyGraph: ComposeDependencyGraph,
        notices: [SupervisionNotice]
    ) {
        self.projectID = projectID
        self.services = services
        self.drift = drift
        self.dependencyGraph = dependencyGraph
        self.notices = notices
    }
}

public struct ComposeSupervisionSnapshot: Codable, Sendable, Equatable {
    public let runID: UUID?
    public let runtimeAvailable: Bool
    public let projects: [ProjectSupervisionSnapshot]
    public let notices: [SupervisionNotice]
    public let generatedAt: Date

    public init(
        runID: UUID?,
        runtimeAvailable: Bool,
        projects: [ProjectSupervisionSnapshot],
        notices: [SupervisionNotice] = [],
        generatedAt: Date = .now
    ) {
        self.runID = runID
        self.runtimeAvailable = runtimeAvailable
        self.projects = projects
        self.notices = notices
        self.generatedAt = generatedAt
    }
}

public enum ComposeSupervisorError: Error, Sendable, Equatable {
    case alreadyRunning
    case projectNotFound(String)
}

extension ComposeSupervisorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Compose supervision is already running in this frontend."
        case .projectNotFound(let projectID):
            "No persisted Compose project named \(projectID) is available for supervision."
        }
    }
}
