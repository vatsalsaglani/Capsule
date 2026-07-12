import Foundation

/// Typed model of the supported compose subset (plan §4.2). Anything outside
/// this surface is reported by `SupportScanner`, never silently dropped.
public struct ComposeFile: Decodable, Sendable {
    public var name: String?
    public var services: [String: ComposeService]
    public var volumes: [String: TopLevelVolume?]?
    public var networks: [String: TopLevelNetwork?]?

    /// Named volumes with YAML-null bodies (`pgdata:`) normalized in.
    public var namedVolumes: [String: TopLevelVolume] {
        (volumes ?? [:]).mapValues { $0 ?? TopLevelVolume() }
    }

    public var namedNetworks: [String: TopLevelNetwork] {
        (networks ?? [:]).mapValues { $0 ?? TopLevelNetwork() }
    }
}

public struct ComposeService: Decodable, Sendable {
    public var image: String?
    public var build: BuildConfig?
    public var command: StringOrList?
    public var entrypoint: StringOrList?
    public var environment: EnvironmentMap?
    public var envFile: StringOrList?
    public var workingDir: String?
    public var user: String?
    public var volumes: [VolumeMount]?
    public var ports: [PortMapping]?
    public var dependsOn: DependsOn?
    public var healthcheck: Healthcheck?
    public var restart: RestartMode?
    public var labels: EnvironmentMap?
    public var networks: StringOrList?
    public var platform: String?
    public var initProcess: Bool?
    public var readOnly: Bool?
    public var shmSize: FlexibleString?
    public var tmpfs: StringOrList?
    public var stopGracePeriod: String?

    enum CodingKeys: String, CodingKey {
        case image, build, command, entrypoint, environment
        case envFile = "env_file"
        case workingDir = "working_dir"
        case user, volumes, ports
        case dependsOn = "depends_on"
        case healthcheck, restart, labels, networks, platform
        case initProcess = "init"
        case readOnly = "read_only"
        case shmSize = "shm_size"
        case tmpfs
        case stopGracePeriod = "stop_grace_period"
    }
}

public struct BuildConfig: Decodable, Sendable, Equatable {
    public var context: String
    public var dockerfile: String?
    public var args: EnvironmentMap?
    public var target: String?

    public init(context: String, dockerfile: String? = nil, args: EnvironmentMap? = nil, target: String? = nil) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case context, dockerfile, args, target
    }

    public init(from decoder: Decoder) throws {
        if let context = try? decoder.singleValueContainer().decode(String.self) {
            self.init(context: context)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try container.decodeIfPresent(String.self, forKey: .context) ?? ".",
            dockerfile: try container.decodeIfPresent(String.self, forKey: .dockerfile),
            args: try container.decodeIfPresent(EnvironmentMap.self, forKey: .args),
            target: try container.decodeIfPresent(String.self, forKey: .target)
        )
    }
}

public struct DependsOn: Decodable, Sendable, Equatable {
    public enum Condition: String, Decodable, Sendable {
        case serviceStarted = "service_started"
        case serviceHealthy = "service_healthy"
        case serviceCompletedSuccessfully = "service_completed_successfully"
    }

    public struct Requirement: Decodable, Sendable, Equatable {
        public var condition: Condition

        public init(condition: Condition = .serviceStarted) {
            self.condition = condition
        }

        private enum CodingKeys: String, CodingKey { case condition }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            condition = try container.decodeIfPresent(Condition.self, forKey: .condition) ?? .serviceStarted
        }
    }

    public let requirements: [String: Requirement]

    public init(requirements: [String: Requirement]) {
        self.requirements = requirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let names = try? container.decode([String].self) {
            requirements = Dictionary(
                names.map { ($0, Requirement()) },
                uniquingKeysWith: { first, _ in first }
            )
        } else if let map = try? container.decode([String: Requirement?].self) {
            requirements = map.mapValues { $0 ?? Requirement() }
        } else {
            throw DecodingError.typeMismatch(
                DependsOn.self,
                .init(codingPath: decoder.codingPath, debugDescription: "expected list or map of services")
            )
        }
    }
}

public struct Healthcheck: Decodable, Sendable, Equatable {
    public var test: StringOrList?
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var startPeriod: String?
    public var disable: Bool?

    private enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries
        case startPeriod = "start_period"
        case disable
    }
}

public enum RestartMode: Decodable, Sendable, Equatable {
    case no
    case always
    case unlessStopped
    case onFailure(maxRetries: Int?)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // YAML 1.1 "Norway problem": an unquoted `restart: no` arrives as
        // Bool(false), not the string "no".
        if let bool = try? container.decode(Bool.self), bool == false {
            self = .no
            return
        }
        let raw = try container.decode(String.self)
        switch raw {
        case "no", "none": self = .no
        case "always": self = .always
        case "unless-stopped": self = .unlessStopped
        case "on-failure": self = .onFailure(maxRetries: nil)
        default:
            if raw.hasPrefix("on-failure:"), let max = Int(raw.dropFirst("on-failure:".count)) {
                self = .onFailure(maxRetries: max)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unsupported restart mode '\(raw)'"
                )
            }
        }
    }
}

public struct TopLevelVolume: Decodable, Sendable, Equatable {
    public var external: Bool?
    public var name: String?

    public init(external: Bool? = nil, name: String? = nil) {
        self.external = external
        self.name = name
    }
}

public struct TopLevelNetwork: Decodable, Sendable, Equatable {
    public var external: Bool?
    public var name: String?
    public var isInternal: Bool?

    public init(external: Bool? = nil, name: String? = nil, isInternal: Bool? = nil) {
        self.external = external
        self.name = name
        self.isInternal = isInternal
    }

    private enum CodingKeys: String, CodingKey {
        case external, name
        case isInternal = "internal"
    }
}
