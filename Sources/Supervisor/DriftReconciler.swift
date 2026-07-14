import ContainerClient
import Foundation

public struct DesiredServiceInstance: Sendable, Codable, Equatable {
    public var service: String
    public var index: Int
    public var containerName: String
    public var configHash: String
    public var shouldRun: Bool

    public init(
        service: String,
        index: Int = 1,
        containerName: String,
        configHash: String,
        shouldRun: Bool
    ) {
        self.service = service
        self.index = index
        self.containerName = containerName
        self.configHash = configHash
        self.shouldRun = shouldRun
    }
}

public enum ServiceDriftKind: String, Sendable, Codable, Equatable {
    case missing
    case unexpectedState
    case configurationChanged
    case orphan
}

public struct ServiceDrift: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(service)-\(index)-\(kind.rawValue)" }
    public var service: String
    public var index: Int
    public var containerID: String?
    public var kind: ServiceDriftKind
    public var message: String

    public init(
        service: String,
        index: Int,
        containerID: String?,
        kind: ServiceDriftKind,
        message: String
    ) {
        self.service = service
        self.index = index
        self.containerID = containerID
        self.kind = kind
        self.message = message
    }
}

public struct DriftReport: Sendable, Codable, Equatable {
    public var project: String
    public var findings: [ServiceDrift]

    public init(project: String, findings: [ServiceDrift]) {
        self.project = project
        self.findings = findings
    }

    public var isInSync: Bool { findings.isEmpty }
}

/// Pure label-based desired-vs-observed comparison. Auto-heal is deliberately
/// outside this type so the same report can be shown before any mutation.
public enum DriftReconciler {
    public static func report(
        project: String,
        desired: [DesiredServiceInstance],
        observed: [ContainerSummary]
    ) -> DriftReport {
        let projectContainers = observed.filter { $0.labels["capsule.project"] == project }
        let desiredByKey = Dictionary(
            desired.map { (key(service: $0.service, index: $0.index), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let observedByKey = Dictionary(
            projectContainers.compactMap { container -> (String, ContainerSummary)? in
                guard let service = container.labels["capsule.service"],
                      let rawIndex = container.labels["capsule.index"],
                      let index = Int(rawIndex)
                else { return nil }
                return (key(service: service, index: index), container)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var findings: [ServiceDrift] = []
        for desiredInstance in desired.sorted(by: order) {
            let instanceKey = key(service: desiredInstance.service, index: desiredInstance.index)
            guard let container = observedByKey[instanceKey] else {
                // Absence is the converged state after `compose down` (or an
                // intentional stopped-and-removed instance), not drift.
                guard desiredInstance.shouldRun else { continue }
                findings.append(.init(
                    service: desiredInstance.service,
                    index: desiredInstance.index,
                    containerID: nil,
                    kind: .missing,
                    message: "Expected container \(desiredInstance.containerName) is missing."
                ))
                continue
            }
            if container.labels["capsule.config-hash"] != desiredInstance.configHash {
                findings.append(.init(
                    service: desiredInstance.service,
                    index: desiredInstance.index,
                    containerID: container.id,
                    kind: .configurationChanged,
                    message: "Observed configuration hash differs from the resolved project."
                ))
            }
            let isRunning = container.runState == .running
            if isRunning != desiredInstance.shouldRun {
                findings.append(.init(
                    service: desiredInstance.service,
                    index: desiredInstance.index,
                    containerID: container.id,
                    kind: .unexpectedState,
                    message: desiredInstance.shouldRun
                        ? "Container is stopped but desired state is running."
                        : "Container is running but desired state is stopped."
                ))
            }
        }

        for (instanceKey, container) in observedByKey where desiredByKey[instanceKey] == nil {
            let service = container.labels["capsule.service"] ?? container.id
            let index = Int(container.labels["capsule.index"] ?? "1") ?? 1
            findings.append(.init(
                service: service,
                index: index,
                containerID: container.id,
                kind: .orphan,
                message: "Container is owned by project \(project) but is absent from resolved configuration."
            ))
        }

        findings.sort {
            if $0.service != $1.service { return $0.service < $1.service }
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return DriftReport(project: project, findings: findings)
    }

    private static func key(service: String, index: Int) -> String { "\(service)#\(index)" }

    private static func order(_ lhs: DesiredServiceInstance, _ rhs: DesiredServiceInstance) -> Bool {
        lhs.service == rhs.service ? lhs.index < rhs.index : lhs.service < rhs.service
    }
}
