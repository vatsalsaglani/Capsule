import Foundation

/// Optional process-level overrides for one non-interactive `exec` call.
/// `user == nil` preserves the container's configured/default identity.
/// The string uses Apple's `name|uid[:gid]` syntax and remains structured
/// data across the future XPC boundary—it is never a raw CLI flag fragment.
public struct ExecOptions: Sendable, Hashable, Codable {
    public var user: String?

    public init(user: String? = nil) {
        self.user = user
    }

    public static let containerDefault = Self()

    /// UID 0 inside the target container VM; this never means host `sudo`.
    public static let containerRoot = Self(user: "0")
}

/// Cache behavior for `container build`.
public enum BuildCachePolicy: String, Sendable, Hashable, Codable {
    case useCache
    case noCache
}

/// Whether a build may use locally cached base images or must refresh them.
public enum BaseImagePolicy: String, Sendable, Hashable, Codable {
    case useLocal
    case pull
}

/// Everything needed to build one image through `ContainerRuntime`.
public struct ImageBuildSpec: Sendable, Hashable, Codable {
    public var contextDirectory: URL
    public var dockerfile: URL?
    public var tag: String
    public var arguments: [String: String]
    public var target: String?
    public var platform: String?
    public var labels: [String: String]
    public var cachePolicy: BuildCachePolicy
    public var baseImagePolicy: BaseImagePolicy

    public init(
        contextDirectory: URL,
        dockerfile: URL? = nil,
        tag: String,
        arguments: [String: String] = [:],
        target: String? = nil,
        platform: String? = nil,
        labels: [String: String] = [:],
        cachePolicy: BuildCachePolicy = .useCache,
        baseImagePolicy: BaseImagePolicy = .useLocal
    ) {
        self.contextDirectory = contextDirectory
        self.dockerfile = dockerfile
        self.tag = tag
        self.arguments = arguments
        self.target = target
        self.platform = platform
        self.labels = labels
        self.cachePolicy = cachePolicy
        self.baseImagePolicy = baseImagePolicy
    }
}

/// One line received from `container build --progress plain`.
public struct BuildProgress: Sendable, Hashable, Codable {
    public let message: String
    public let receivedAt: Date

    public init(message: String, receivedAt: Date = Date()) {
        self.message = message
        self.receivedAt = receivedAt
    }
}

public struct VolumeCreateSpec: Sendable, Hashable, Codable {
    public var name: String
    public var capacityBytes: UInt64?
    public var labels: [String: String]

    public init(name: String, capacityBytes: UInt64? = nil, labels: [String: String] = [:]) {
        self.name = name
        self.capacityBytes = capacityBytes
        self.labels = labels
    }
}

/// Apple's `--internal` network flag creates a host-only network; omitting it
/// creates the ordinary NAT-connected network.
public enum NetworkConnectivity: String, Sendable, Hashable, Codable {
    case nat
    case hostOnly
}

public struct NetworkCreateSpec: Sendable, Hashable, Codable {
    public var name: String
    public var connectivity: NetworkConnectivity
    public var ipv4Subnet: String?
    public var ipv6Subnet: String?
    public var labels: [String: String]

    public init(
        name: String,
        connectivity: NetworkConnectivity = .nat,
        ipv4Subnet: String? = nil,
        ipv6Subnet: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.connectivity = connectivity
        self.ipv4Subnet = ipv4Subnet
        self.ipv6Subnet = ipv6Subnet
        self.labels = labels
    }
}

/// Typed outcome for runtime prune operations. Because Apple's prune commands
/// do not expose JSON, clients derive `removedNames` from before/after lists
/// and preserve any human-readable command output as `notices`.
public struct PruneReport: Sendable, Hashable, Codable {
    public let removedNames: [String]
    public let notices: [String]

    public init(removedNames: [String], notices: [String] = []) {
        self.removedNames = removedNames
        self.notices = notices
    }
}
