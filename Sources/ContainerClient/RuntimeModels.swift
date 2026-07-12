import Foundation

/// Shared decoder for every DTO in this file — dates on the runtime's JSON
/// surface (`creationDate`, `startedDate`, …) are ISO 8601 strings (spike S2).
enum RuntimeJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Strips a CIDR suffix (`"192.168.64.6/24"` → `"192.168.64.6"`). The runtime
/// reports resolved addresses in CIDR form; every UI/plain-address consumer
/// wants the bare address (spike S2 finding #3).
func strippingCIDRSuffix(_ address: String) -> String {
    guard let slashIndex = address.firstIndex(of: "/") else { return address }
    return String(address[..<slashIndex])
}

// MARK: - Shared nested shapes

public struct Platform: Sendable, Hashable, Codable {
    public let architecture: String
    public let os: String
    public let variant: String?

    public init(architecture: String, os: String, variant: String? = nil) {
        self.architecture = architecture
        self.os = os
        self.variant = variant
    }
}

public struct Resources: Sendable, Hashable, Codable {
    public let cpus: Int
    public let memoryInBytes: UInt64

    public init(cpus: Int, memoryInBytes: UInt64) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }
}

/// Resolved network attachment (`status.networks[]`) — distinct from the
/// *requested* attachment at `configuration.networks[]`, which carries no
/// address (spike S2 finding #3).
public struct NetworkAttachment: Sendable, Hashable, Codable {
    public let hostname: String?
    public let ipv4Address: String?
    public let ipv4Gateway: String?
    public let macAddress: String?
    public let network: String?

    public init(
        hostname: String? = nil,
        ipv4Address: String? = nil,
        ipv4Gateway: String? = nil,
        macAddress: String? = nil,
        network: String? = nil
    ) {
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.network = network
    }

    /// `ipv4Address` with its CIDR suffix stripped, e.g. `"192.168.64.6"`.
    public var ipAddress: String? {
        ipv4Address.map(strippingCIDRSuffix)
    }
}

// MARK: - Container detail

/// Full detail for one container (`container inspect <id>` — no `--format`
/// flag, emits JSON unconditionally; spike S2 finding #7). Shares the
/// `configuration`/`status` nested shape with `ContainerSummary`.
///
/// `mounts` is deliberately omitted — S2 only ever observed an empty array,
/// so the real shape is unverified; add it additively once a populated
/// capture exists.
public struct ContainerDetail: Sendable, Equatable {
    public let id: String
    public let status: String
    public let startedAt: Date?
    public let createdAt: Date?
    public let imageReference: String?
    public let imageDigest: String?
    public let labels: [String: String]
    public let ports: [PortMapping]
    public let networks: [NetworkAttachment]
    public let dns: DNSConfiguration?
    public let platform: Platform?
    public let resources: Resources?
    public let stopSignal: String?
    public let useInit: Bool?
    public let readOnly: Bool?

    public init(
        id: String,
        status: String,
        startedAt: Date? = nil,
        createdAt: Date? = nil,
        imageReference: String? = nil,
        imageDigest: String? = nil,
        labels: [String: String] = [:],
        ports: [PortMapping] = [],
        networks: [NetworkAttachment] = [],
        dns: DNSConfiguration? = nil,
        platform: Platform? = nil,
        resources: Resources? = nil,
        stopSignal: String? = nil,
        useInit: Bool? = nil,
        readOnly: Bool? = nil
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.imageReference = imageReference
        self.imageDigest = imageDigest
        self.labels = labels
        self.ports = ports
        self.networks = networks
        self.dns = dns
        self.platform = platform
        self.resources = resources
        self.stopSignal = stopSignal
        self.useInit = useInit
        self.readOnly = readOnly
    }

    public var runState: ContainerRunState {
        ContainerRunState(rawValue: status.lowercased()) ?? .unknown
    }
}

extension ContainerDetail: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, status, configuration
    }
    private enum StatusKeys: String, CodingKey {
        case state, startedDate, networks
    }
    private enum ConfigurationKeys: String, CodingKey {
        case creationDate, image, labels, publishedPorts, dns, platform, resources, stopSignal, useInit, readOnly
    }
    private enum ImageKeys: String, CodingKey {
        case reference, descriptor
    }
    private enum DescriptorKeys: String, CodingKey {
        case digest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)

        let statusContainer = try container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        let status = try statusContainer.decode(String.self, forKey: .state)
        let startedAt = try statusContainer.decodeIfPresent(Date.self, forKey: .startedDate)
        let networks = (try? statusContainer.decode([NetworkAttachment].self, forKey: .networks)) ?? []

        var createdAt: Date?
        var imageReference: String?
        var imageDigest: String?
        var labels: [String: String] = [:]
        var ports: [PortMapping] = []
        var dns: DNSConfiguration?
        var platform: Platform?
        var resources: Resources?
        var stopSignal: String?
        var useInit: Bool?
        var readOnly: Bool?

        if let configuration = try? container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration) {
            createdAt = try configuration.decodeIfPresent(Date.self, forKey: .creationDate)
            labels = (try? configuration.decode([String: String].self, forKey: .labels)) ?? [:]
            ports = (try? configuration.decode([PortMapping].self, forKey: .publishedPorts)) ?? []
            dns = try configuration.decodeIfPresent(DNSConfiguration.self, forKey: .dns)
            platform = try configuration.decodeIfPresent(Platform.self, forKey: .platform)
            resources = try configuration.decodeIfPresent(Resources.self, forKey: .resources)
            stopSignal = try configuration.decodeIfPresent(String.self, forKey: .stopSignal)
            useInit = try configuration.decodeIfPresent(Bool.self, forKey: .useInit)
            readOnly = try configuration.decodeIfPresent(Bool.self, forKey: .readOnly)

            if let imageContainer = try? configuration.nestedContainer(keyedBy: ImageKeys.self, forKey: .image) {
                imageReference = try imageContainer.decodeIfPresent(String.self, forKey: .reference)
                if let descriptorContainer = try? imageContainer.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .descriptor) {
                    imageDigest = try descriptorContainer.decodeIfPresent(String.self, forKey: .digest)
                }
            }
        }

        self.init(
            id: id,
            status: status,
            startedAt: startedAt,
            createdAt: createdAt,
            imageReference: imageReference,
            imageDigest: imageDigest,
            labels: labels,
            ports: ports,
            networks: networks,
            dns: dns,
            platform: platform,
            resources: resources,
            stopSignal: stopSignal,
            useInit: useInit,
            readOnly: readOnly
        )
    }
}

// MARK: - Logs / exec / stats

public struct LogLine: Sendable, Equatable {
    public let text: String
    public let receivedAt: Date

    /// `text` has any trailing newline stripped; `receivedAt` defaults to the
    /// moment of host receipt (the runtime does not timestamp log lines).
    public init(text: String, receivedAt: Date = Date()) {
        var stripped = text
        if stripped.hasSuffix("\n") { stripped.removeLast() }
        if stripped.hasSuffix("\r") { stripped.removeLast() }
        self.text = stripped
        self.receivedAt = receivedAt
    }
}

public struct ExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// One `container stats --format json` sample. Flat object, byte/usec units —
/// no human-formatted-string parsing needed (spike S2 finding #9).
public struct StatsSample: Sendable, Equatable {
    public let id: String
    public let cpuUsageMicroseconds: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    public let blockReadBytes: UInt64
    public let blockWriteBytes: UInt64
    public let networkReceivedBytes: UInt64
    public let networkSentBytes: UInt64
    public let processCount: Int

    public init(
        id: String,
        cpuUsageMicroseconds: UInt64,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        networkReceivedBytes: UInt64,
        networkSentBytes: UInt64,
        processCount: Int
    ) {
        self.id = id
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.networkReceivedBytes = networkReceivedBytes
        self.networkSentBytes = networkSentBytes
        self.processCount = processCount
    }
}

extension StatsSample: Codable {
    // Verbatim S2 capture: {"blockReadBytes":21536768,"blockWriteBytes":8192,
    // "cpuUsageUsec":19568,"id":"s2-probe","memoryLimitBytes":1073741824,
    // "memoryUsageBytes":27713536,"networkRxBytes":21834,"networkTxBytes":602,
    // "numProcesses":6} — four keys differ from their property names.
    private enum CodingKeys: String, CodingKey {
        case id
        case cpuUsageMicroseconds = "cpuUsageUsec"
        case memoryUsageBytes
        case memoryLimitBytes
        case blockReadBytes
        case blockWriteBytes
        case networkReceivedBytes = "networkRxBytes"
        case networkSentBytes = "networkTxBytes"
        case processCount = "numProcesses"
    }
}

// MARK: - Images

/// One `container image list --format json` element.
public struct ImageSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let reference: String
    public let digest: String?
    public let createdAt: Date?
    public let platforms: [Platform]

    public init(
        id: String,
        reference: String,
        digest: String? = nil,
        createdAt: Date? = nil,
        platforms: [Platform] = []
    ) {
        self.id = id
        self.reference = reference
        self.digest = digest
        self.createdAt = createdAt
        self.platforms = platforms
    }
}

extension ImageSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, configuration, variants
    }
    private enum ConfigurationKeys: String, CodingKey {
        case name, descriptor, creationDate
    }
    private enum DescriptorKeys: String, CodingKey {
        case digest
    }
    private struct Variant: Decodable {
        let platform: Platform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let configuration = try container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration)
        let reference = try configuration.decode(String.self, forKey: .name)
        let createdAt = try configuration.decodeIfPresent(Date.self, forKey: .creationDate)

        var digest: String?
        if let descriptorContainer = try? configuration.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .descriptor) {
            digest = try descriptorContainer.decodeIfPresent(String.self, forKey: .digest)
        }

        let variants = (try? container.decode([Variant].self, forKey: .variants)) ?? []
        self.init(id: id, reference: reference, digest: digest, createdAt: createdAt, platforms: variants.map(\.platform))
    }
}

/// One `container pull` progress line — pull emits plain text lines, not JSON.
public struct PullProgress: Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Volumes

/// One `container volume ls --format json` element (spike S2 §3).
public struct VolumeSummary: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let driver: String?
    public let format: String?
    public let sizeInBytes: UInt64?
    public let source: String?
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        driver: String? = nil,
        format: String? = nil,
        sizeInBytes: UInt64? = nil,
        source: String? = nil,
        labels: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.driver = driver
        self.format = format
        self.sizeInBytes = sizeInBytes
        self.source = source
        self.labels = labels
        self.createdAt = createdAt
    }
}

extension VolumeSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case configuration
    }
    private enum ConfigurationKeys: String, CodingKey {
        case name, driver, format, sizeInBytes, source, labels, creationDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration)
        self.init(
            name: try configuration.decode(String.self, forKey: .name),
            driver: try configuration.decodeIfPresent(String.self, forKey: .driver),
            format: try configuration.decodeIfPresent(String.self, forKey: .format),
            sizeInBytes: try configuration.decodeIfPresent(UInt64.self, forKey: .sizeInBytes),
            source: try configuration.decodeIfPresent(String.self, forKey: .source),
            labels: (try? configuration.decode([String: String].self, forKey: .labels)) ?? [:],
            createdAt: try configuration.decodeIfPresent(Date.self, forKey: .creationDate)
        )
    }
}

// MARK: - Networks

public struct NetworkStatus: Sendable, Hashable, Codable {
    public let ipv4Gateway: String?
    public let ipv4Subnet: String?
    public let ipv6Subnet: String?

    public init(ipv4Gateway: String? = nil, ipv4Subnet: String? = nil, ipv6Subnet: String? = nil) {
        self.ipv4Gateway = ipv4Gateway
        self.ipv4Subnet = ipv4Subnet
        self.ipv6Subnet = ipv6Subnet
    }
}

/// One `container network ls --format json` element (spike S2 §4). The
/// built-in `default` network carries the label
/// `com.apple.container.resource.role: builtin` — not a `capsule.*` label;
/// don't confuse the two when the compose engine filters by project label.
public struct NetworkSummary: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let mode: String?
    public let plugin: String?
    public let labels: [String: String]
    public let createdAt: Date?
    public let status: NetworkStatus?

    public init(
        name: String,
        mode: String? = nil,
        plugin: String? = nil,
        labels: [String: String] = [:],
        createdAt: Date? = nil,
        status: NetworkStatus? = nil
    ) {
        self.name = name
        self.mode = mode
        self.plugin = plugin
        self.labels = labels
        self.createdAt = createdAt
        self.status = status
    }
}

extension NetworkSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, configuration, status
    }
    private enum ConfigurationKeys: String, CodingKey {
        case mode, plugin, labels, creationDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .id)
        let configuration = try container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration)
        self.init(
            name: name,
            mode: try configuration.decodeIfPresent(String.self, forKey: .mode),
            plugin: try configuration.decodeIfPresent(String.self, forKey: .plugin),
            labels: (try? configuration.decode([String: String].self, forKey: .labels)) ?? [:],
            createdAt: try configuration.decodeIfPresent(Date.self, forKey: .creationDate),
            status: try container.decodeIfPresent(NetworkStatus.self, forKey: .status)
        )
    }
}

// MARK: - System

/// `container system df --format json` — flat per-resource-type objects, no
/// human-formatted-size parsing needed (spike S2 finding #10).
public struct ResourceUsage: Sendable, Hashable, Codable {
    public let total: Int
    public let active: Int
    public let sizeInBytes: UInt64
    public let reclaimableBytes: UInt64

    public init(total: Int, active: Int, sizeInBytes: UInt64, reclaimableBytes: UInt64) {
        self.total = total
        self.active = active
        self.sizeInBytes = sizeInBytes
        self.reclaimableBytes = reclaimableBytes
    }

    private enum CodingKeys: String, CodingKey {
        case total, active, sizeInBytes
        case reclaimableBytes = "reclaimable"
    }
}

public struct SystemDiskUsage: Sendable, Equatable, Codable {
    public let containers: ResourceUsage
    public let images: ResourceUsage
    public let volumes: ResourceUsage

    public init(containers: ResourceUsage, images: ResourceUsage, volumes: ResourceUsage) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }
}

/// `container system status --format json` — flat, no nesting (spike S2
/// finding #5, correcting the earlier "no `--format` flag tested yet" note).
public struct SystemStatus: Sendable, Equatable, Codable {
    public let status: String
    public let apiServerVersion: String?
    public let apiServerAppName: String?
    public let apiServerBuild: String?
    public let apiServerCommit: String?
    public let appRoot: String?
    public let installRoot: String?

    public init(
        status: String,
        apiServerVersion: String? = nil,
        apiServerAppName: String? = nil,
        apiServerBuild: String? = nil,
        apiServerCommit: String? = nil,
        appRoot: String? = nil,
        installRoot: String? = nil
    ) {
        self.status = status
        self.apiServerVersion = apiServerVersion
        self.apiServerAppName = apiServerAppName
        self.apiServerBuild = apiServerBuild
        self.apiServerCommit = apiServerCommit
        self.appRoot = appRoot
        self.installRoot = installRoot
    }

    public var isRunning: Bool { status == "running" }
}
