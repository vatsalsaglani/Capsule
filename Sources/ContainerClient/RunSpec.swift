import Foundation

/// Everything needed to build a `container create` invocation (plan §4.3).
/// Pure data — no argv-building logic lives here yet. Targets `create`, not
/// `run` — `run` is create+start and would break the planner's
/// `EnsureContainer`→`Start` separation (plan §4.5); `create`'s flags are a
/// flag-identical subset for everything this spec expresses.
///
/// **`RunSpec` → argv mapping table** (golden-tested in the P1A
/// *implementation* PR, not this Contract PR):
///
/// | Field | Flag |
/// |---|---|
/// | `name` | `--name` |
/// | `entrypoint` | `--entrypoint` |
/// | `environment` | `-e k=v`, one per entry, sorted by key |
/// | `workingDirectory` | `-w` |
/// | `user` | `-u` |
/// | `ports[i]` | `-p [hostAddress:]hostPort:containerPort/proto` (proto always explicit) |
/// | `mounts[i]` `.bind(ro: false)` | `-v src:tgt` |
/// | `mounts[i]` `.bind(ro: true)` | `--mount type=bind,source=,target=,readonly` |
/// | `mounts[i]` `.volume(ro: false)` | `-v name:tgt` |
/// | `mounts[i]` `.volume(ro: true)` | `--mount type=volume,source=name,target=,readonly` |
/// | `mounts[i]` `.tmpfs` | `--tmpfs /target` |
/// | `networks[i]` | `--network`, one per entry |
/// | `platform` | `--platform` |
/// | `rosetta` | `--rosetta` |
/// | `useInit` | `--init` |
/// | `labels` | `-l k=v`, one per entry, sorted by key |
/// | `dns.nameservers[i]` | `--dns`, one per entry |
/// | `dns.searchDomains[i]` | `--dns-search`, one per entry |
/// | `dns.options[i]` | `--dns-option`, one per entry |
/// | `dns.domain` | `--dns-domain` |
/// | `readOnly` | `--read-only` |
/// | `shmSize` | `--shm-size` |
/// | `image` | positional, after all flags |
/// | `command` | trailing positionals |
public struct RunSpec: Sendable, Hashable, Codable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var entrypoint: String?
    public var environment: [String: String]
    public var workingDirectory: String?
    public var user: String?
    public var ports: [PortMapping]
    public var mounts: [Mount]
    public var networks: [String]
    public var platform: String?
    public var rosetta: Bool
    /// Runtime JSON key `useInit`; `init` is a Swift keyword.
    public var useInit: Bool
    public var labels: [String: String]
    public var dns: DNSConfiguration?
    public var readOnly: Bool
    public var shmSize: String?

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.entrypoint = nil
        self.environment = [:]
        self.workingDirectory = nil
        self.user = nil
        self.ports = []
        self.mounts = []
        self.networks = []
        self.platform = nil
        self.rosetta = false
        self.useInit = false
        self.labels = [:]
        self.dns = nil
        self.readOnly = false
        self.shmSize = nil
    }
}

/// Shared between `RunSpec` (input, `-p`/`--publish`) and the decoded
/// `configuration.publishedPorts[]` on `ContainerSummary`/`ContainerDetail`
/// (output) — one shape for both directions.
public struct PortMapping: Sendable, Hashable, Codable {
    /// `nil` means "0.0.0.0" (all interfaces).
    public var hostAddress: String?
    public var hostPort: Int
    public var containerPort: Int
    public var proto: PortProtocol
    /// Default 1; runtime JSON key `publishedPorts[].count`.
    public var count: Int

    public init(
        hostAddress: String? = nil,
        hostPort: Int,
        containerPort: Int,
        proto: PortProtocol = .tcp,
        count: Int = 1
    ) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }

    // Explicit for self-documentation against the S2 verbatim capture
    // (`{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":8099,"proto":"tcp"}`)
    // — field names already match 1:1, so this is an identity mapping.
    private enum CodingKeys: String, CodingKey {
        case hostAddress, hostPort, containerPort, proto, count
    }
}

public enum PortProtocol: String, Sendable, Hashable, Codable {
    case tcp
    case udp
}

public enum Mount: Sendable, Hashable, Codable {
    case bind(source: String, target: String, readOnly: Bool)
    case volume(name: String, target: String, readOnly: Bool)
    case tmpfs(target: String)
}

public struct DNSConfiguration: Sendable, Hashable, Codable {
    public var nameservers: [String]
    public var searchDomains: [String]
    public var options: [String]
    public var domain: String?

    public init(
        nameservers: [String] = [],
        searchDomains: [String] = [],
        options: [String] = [],
        domain: String? = nil
    ) {
        self.nameservers = nameservers
        self.searchDomains = searchDomains
        self.options = options
        self.domain = domain
    }
}
