import Foundation

// MARK: - Builder

/// The builder container has three materially different lifecycle states.
/// `stop` leaves a reusable builder behind; `delete` returns it to `absent`.
public enum BuilderState: Sendable, Hashable, Codable {
    case absent
    case stopped
    case running
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "absent": self = .absent
        case "stopped": self = .stopped
        case "running": self = .running
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .absent: "absent"
        case .stopped: "stopped"
        case .running: "running"
        case .unknown(let value): value
        }
    }
}

public struct BuilderConfiguration: Sendable, Hashable, Codable {
    public var cpus: Int?
    public var memoryBytes: UInt64?

    public init(cpus: Int? = nil, memoryBytes: UInt64? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }
}

public struct BuilderStatus: Sendable, Hashable, Codable {
    public var state: BuilderState
    public var containerID: String?
    public var imageReference: String?
    public var ipAddresses: [String]
    public var cpus: Int?
    public var memoryBytes: UInt64?

    public init(
        state: BuilderState,
        containerID: String? = nil,
        imageReference: String? = nil,
        ipAddresses: [String] = [],
        cpus: Int? = nil,
        memoryBytes: UInt64? = nil
    ) {
        self.state = state
        self.containerID = containerID
        self.imageReference = imageReference
        self.ipAddresses = ipAddresses
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }

    public static let absent = Self(state: .absent)
}

// MARK: - Machines

/// Raw runtime values are preserved so a new Apple state remains visible
/// instead of making the whole machine list undecodable.
public enum MachineState: Sendable, Hashable, Codable {
    case unknown
    case stopped
    case running
    case stopping
    case other(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "unknown": self = .unknown
        case "stopped": self = .stopped
        case "running": self = .running
        case "stopping": self = .stopping
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .unknown: "unknown"
        case .stopped: "stopped"
        case .running: "running"
        case .stopping: "stopping"
        case .other(let value): value
        }
    }
}

public enum MachineHomeMount: String, Sendable, Hashable, Codable, CaseIterable {
    case readWrite = "rw"
    case readOnly = "ro"
    case none
}

public struct MachineSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let state: MachineState
    public let isDefault: Bool
    public let ipAddress: String?
    public let cpus: Int
    public let memoryBytes: UInt64
    public let diskSizeBytes: UInt64?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case state = "status"
        case isDefault = "default"
        case ipAddress
        case cpus
        case memoryBytes = "memory"
        case diskSizeBytes = "diskSize"
        case createdAt = "createdDate"
    }

    public init(
        id: String,
        state: MachineState,
        isDefault: Bool = false,
        ipAddress: String? = nil,
        cpus: Int,
        memoryBytes: UInt64,
        diskSizeBytes: UInt64? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.isDefault = isDefault
        self.ipAddress = ipAddress
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSizeBytes = diskSizeBytes
        self.createdAt = createdAt
    }
}

public struct MachineDetail: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let imageReference: String
    public let operatingSystem: String
    public let architecture: String
    public let state: MachineState
    public let startedAt: Date?
    public let createdAt: Date?
    public let containerID: String?
    public let cpus: Int
    public let memoryBytes: UInt64
    public let homeMount: MachineHomeMount
    public let diskSizeBytes: UInt64?
    public let ipAddress: String?

    enum CodingKeys: String, CodingKey {
        case id, image, platform
        case state = "status"
        case startedAt = "startedDate"
        case createdAt = "createdDate"
        case containerID = "containerId"
        case cpus
        case memoryBytes = "memory"
        case homeMount
        case diskSizeBytes = "diskSize"
        case ipAddress
    }

    private struct Image: Codable { let reference: String }
    private struct Platform: Codable { let os: String; let architecture: String }

    public init(
        id: String,
        imageReference: String,
        operatingSystem: String,
        architecture: String,
        state: MachineState,
        startedAt: Date? = nil,
        createdAt: Date? = nil,
        containerID: String? = nil,
        cpus: Int,
        memoryBytes: UInt64,
        homeMount: MachineHomeMount,
        diskSizeBytes: UInt64? = nil,
        ipAddress: String? = nil
    ) {
        self.id = id
        self.imageReference = imageReference
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.state = state
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.containerID = containerID
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.homeMount = homeMount
        self.diskSizeBytes = diskSizeBytes
        self.ipAddress = ipAddress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let image = try container.decode(Image.self, forKey: .image)
        let platform = try container.decode(Platform.self, forKey: .platform)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            imageReference: image.reference,
            operatingSystem: platform.os,
            architecture: platform.architecture,
            state: try container.decode(MachineState.self, forKey: .state),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            containerID: try container.decodeIfPresent(String.self, forKey: .containerID),
            cpus: try container.decode(Int.self, forKey: .cpus),
            memoryBytes: try container.decode(UInt64.self, forKey: .memoryBytes),
            homeMount: try container.decode(MachineHomeMount.self, forKey: .homeMount),
            diskSizeBytes: try container.decodeIfPresent(UInt64.self, forKey: .diskSizeBytes),
            ipAddress: try container.decodeIfPresent(String.self, forKey: .ipAddress)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Image(reference: imageReference), forKey: .image)
        try container.encode(Platform(os: operatingSystem, architecture: architecture), forKey: .platform)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(containerID, forKey: .containerID)
        try container.encode(cpus, forKey: .cpus)
        try container.encode(memoryBytes, forKey: .memoryBytes)
        try container.encode(homeMount, forKey: .homeMount)
        try container.encodeIfPresent(diskSizeBytes, forKey: .diskSizeBytes)
        try container.encodeIfPresent(ipAddress, forKey: .ipAddress)
    }
}

public struct MachineCreateSpec: Sendable, Hashable, Codable {
    public var imageReference: String
    public var name: String?
    public var platform: String?
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var homeMount: MachineHomeMount
    public var bootAfterCreation: Bool
    public var setAsDefault: Bool
    public var nestedVirtualization: Bool

    public init(
        imageReference: String,
        name: String? = nil,
        platform: String? = nil,
        cpus: Int? = nil,
        memoryBytes: UInt64? = nil,
        homeMount: MachineHomeMount = .readWrite,
        bootAfterCreation: Bool = true,
        setAsDefault: Bool = false,
        nestedVirtualization: Bool = false
    ) {
        self.imageReference = imageReference
        self.name = name
        self.platform = platform
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.homeMount = homeMount
        self.bootAfterCreation = bootAfterCreation
        self.setAsDefault = setAsDefault
        self.nestedVirtualization = nestedVirtualization
    }
}

public enum MachineLogSource: String, Sendable, Hashable, Codable, CaseIterable {
    case standard
    case boot
}
