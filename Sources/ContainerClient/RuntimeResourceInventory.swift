import Foundation

public enum ResourceOwner: Sendable, Hashable, Codable {
    case capsule(project: String?)
    case external
    case system
}

public struct ContainerReference: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let project: String?
    public let service: String?

    public init(id: String, project: String? = nil, service: String? = nil) {
        self.id = id
        self.project = project
        self.service = service
    }
}

public struct VolumeRecord: Sendable, Equatable, Identifiable {
    public var id: String { summary.name }
    public let summary: VolumeSummary
    public let usedBy: [ContainerReference]
    public let owner: ResourceOwner

    public init(summary: VolumeSummary, usedBy: [ContainerReference], owner: ResourceOwner) {
        self.summary = summary
        self.usedBy = usedBy
        self.owner = owner
    }
}

public struct NetworkRecord: Sendable, Equatable, Identifiable {
    public var id: String { summary.name }
    public let summary: NetworkSummary
    public let connectedContainers: [ContainerReference]
    public let owner: ResourceOwner
    public let isBuiltIn: Bool

    public init(
        summary: NetworkSummary,
        connectedContainers: [ContainerReference],
        owner: ResourceOwner,
        isBuiltIn: Bool
    ) {
        self.summary = summary
        self.connectedContainers = connectedContainers
        self.owner = owner
        self.isBuiltIn = isBuiltIn
    }
}

/// Read-model used by the Volumes and Networks frontends. Apple exposes
/// resource lists but not reverse references, so the inventory derives those
/// relationships from container inspect data in CapsuleKit.
public struct RuntimeResourceInventory: Sendable, Equatable {
    public let volumes: [VolumeRecord]
    public let networks: [NetworkRecord]

    public init(
        volumes: [VolumeSummary],
        networks: [NetworkSummary],
        containerDetails: [ContainerDetail]
    ) {
        let referencesByID = Dictionary(uniqueKeysWithValues: containerDetails.map { detail in
            (detail.id, ContainerReference(
                id: detail.id,
                project: detail.labels["capsule.project"],
                service: detail.labels["capsule.service"]
            ))
        })

        var volumeUsers: [String: Set<ContainerReference>] = [:]
        var networkUsers: [String: Set<ContainerReference>] = [:]

        for detail in containerDetails {
            guard let reference = referencesByID[detail.id] else { continue }
            for mount in detail.mounts {
                guard case .volume(let configuredName) = mount.kind,
                      let name = configuredName ?? mount.source,
                      !name.isEmpty
                else { continue }
                volumeUsers[name, default: []].insert(reference)
            }

            let requested = detail.requestedNetworks
            let resolved = detail.networks.compactMap(\.network)
            for name in Set(requested + resolved) where !name.isEmpty {
                networkUsers[name, default: []].insert(reference)
            }
        }

        self.volumes = volumes
            .map { summary in
                VolumeRecord(
                    summary: summary,
                    usedBy: Self.sortedReferences(volumeUsers[summary.name] ?? []),
                    owner: Self.owner(for: summary.labels, isBuiltIn: false)
                )
            }
            .sorted { $0.summary.name < $1.summary.name }

        self.networks = networks
            .map { summary in
                let isBuiltIn = summary.labels["com.apple.container.resource.role"] == "builtin"
                return NetworkRecord(
                    summary: summary,
                    connectedContainers: Self.sortedReferences(networkUsers[summary.name] ?? []),
                    owner: Self.owner(for: summary.labels, isBuiltIn: isBuiltIn),
                    isBuiltIn: isBuiltIn
                )
            }
            .sorted { $0.summary.name < $1.summary.name }
    }

    /// Loads the three runtime surfaces concurrently, then inspects containers
    /// concurrently with structured cancellation and error propagation.
    public static func load(from runtime: any ContainerRuntime) async throws -> RuntimeResourceInventory {
        async let volumes = runtime.listVolumes()
        async let networks = runtime.listNetworks()
        let containers = try await runtime.listContainers(all: true)

        let details = try await withThrowingTaskGroup(of: ContainerDetail?.self) { group in
            for container in containers {
                group.addTask {
                    do {
                        return try await runtime.inspectContainer(id: container.id)
                    } catch RuntimeError.resourceNotFound {
                        // Normal list→inspect churn: the container disappeared
                        // after the snapshot. Other typed failures remain loud.
                        return nil
                    }
                }
            }

            var result: [ContainerDetail] = []
            result.reserveCapacity(containers.count)
            for try await detail in group {
                if let detail { result.append(detail) }
            }
            return result.sorted { $0.id < $1.id }
        }

        return try await RuntimeResourceInventory(
            volumes: volumes,
            networks: networks,
            containerDetails: details
        )
    }

    /// Exact-name lookup; resource names are identifiers, not fuzzy search.
    public func volume(named name: String) -> VolumeRecord? {
        volumes.first { $0.summary.name == name }
    }

    /// Exact-name lookup; resource names are identifiers, not fuzzy search.
    public func network(named name: String) -> NetworkRecord? {
        networks.first { $0.summary.name == name }
    }

    private static func sortedReferences(_ references: Set<ContainerReference>) -> [ContainerReference] {
        references.sorted { $0.id < $1.id }
    }

    private static func owner(for labels: [String: String], isBuiltIn: Bool) -> ResourceOwner {
        if isBuiltIn { return .system }
        if labels.keys.contains(where: { $0.hasPrefix("capsule.") }) {
            return .capsule(project: labels["capsule.project"])
        }
        return .external
    }
}
