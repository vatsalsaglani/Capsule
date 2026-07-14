import Foundation
import Yams

/// "Fail loud on anything else" (plan §4.2): every key we don't act on is
/// reported, per-key policy warning (ignored) vs fatal.
public struct SupportReport: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable, Hashable {
        case warning
        case fatal
    }

    public struct Finding: Codable, Sendable, Hashable {
        public let path: String
        public let message: String
        public let severity: Severity

        public init(path: String, message: String, severity: Severity) {
            self.path = path
            self.message = message
            self.severity = severity
        }
    }

    public let findings: [Finding]

    public init(findings: [Finding]) {
        self.findings = findings
    }

    public var hasFatalFindings: Bool {
        findings.contains { $0.severity == .fatal }
    }

    public var rendered: String {
        guard !findings.isEmpty else { return "support: all keys recognized" }
        return findings
            .map { "\($0.severity == .fatal ? "error" : "warning"): \($0.path) — \($0.message)" }
            .joined(separator: "\n")
    }
}

enum SupportScanner {
    static let knownTopLevelKeys: Set<String> = [
        "name", "version", "services", "volumes", "networks",
    ]

    /// Must stay in sync with ComposeService.CodingKeys.
    static let knownServiceKeys: Set<String> = [
        "image", "build", "command", "entrypoint", "environment", "env_file",
        "working_dir", "user", "volumes", "ports", "depends_on", "healthcheck",
        "restart", "labels", "networks", "platform", "init", "read_only",
        "shm_size", "tmpfs", "stop_grace_period",
    ]

    /// Keys we plan to support in v1.1+ (plan §4.2) — called out explicitly so
    /// users know they are deferred, not unknown.
    static let deferredServiceKeys: Set<String> = [
        "profiles", "extends", "secrets", "configs", "deploy", "develop",
        "pull_policy", "cpus", "mem_limit",
    ]

    private static let knownBuildKeys: Set<String> = ["context", "dockerfile", "args", "target"]
    private static let knownHealthcheckKeys: Set<String> = [
        "test", "interval", "timeout", "retries", "start_period", "disable",
    ]
    private static let knownDependencyKeys: Set<String> = ["condition"]
    private static let knownPortKeys: Set<String> = ["target", "published", "protocol", "host_ip"]
    private static let knownMountKeys: Set<String> = ["type", "source", "target", "read_only"]
    private static let knownVolumeKeys: Set<String> = ["external", "name"]
    private static let knownNetworkKeys: Set<String> = ["external", "name", "internal"]

    static func scan(yaml: String) throws -> [SupportReport.Finding] {
        guard let root = try Yams.compose(yaml: yaml) else { return [] }
        return scan(root: root)
    }

    static func scan(root: Node) -> [SupportReport.Finding] {
        guard case .mapping(let topLevel) = root else { return [] }

        var findings: [SupportReport.Finding] = []
        for (keyNode, valueNode) in topLevel {
            guard let key = keyNode.string else { continue }
            if key == "version" {
                findings.append(.init(
                    path: "version",
                    message: "obsolete in the compose spec (ignored)",
                    severity: .warning
                ))
                continue
            }
            if !knownTopLevelKeys.contains(key) {
                findings.append(.init(
                    path: key,
                    message: "unsupported top-level key (ignored)",
                    severity: .warning
                ))
                continue
            }
            if key == "services", case .mapping(let services) = valueNode {
                findings.append(contentsOf: scanServices(services))
            } else if key == "volumes", case .mapping(let volumes) = valueNode {
                findings.append(contentsOf: scanNamedResources(volumes, root: "volumes", knownKeys: knownVolumeKeys))
            } else if key == "networks", case .mapping(let networks) = valueNode {
                findings.append(contentsOf: scanNamedResources(networks, root: "networks", knownKeys: knownNetworkKeys))
            }
        }
        return findings
    }

    private static func scanServices(_ services: Yams.Node.Mapping) -> [SupportReport.Finding] {
        var findings: [SupportReport.Finding] = []
        for (serviceNameNode, serviceNode) in services {
            guard let serviceName = serviceNameNode.string,
                  case .mapping(let body) = serviceNode
            else { continue }
            for (keyNode, valueNode) in body {
                guard let key = keyNode.string else { continue }
                let path = "services.\(serviceName).\(key)"
                guard knownServiceKeys.contains(key) else {
                    let message = deferredServiceKeys.contains(key)
                        ? "planned for v1.1+ (ignored for now)"
                        : "unsupported key (ignored)"
                    findings.append(.init(path: path, message: message, severity: .warning))
                    continue
                }
                switch key {
                case "build":
                    findings.append(contentsOf: scanMapping(valueNode, path: path, knownKeys: knownBuildKeys))
                case "healthcheck":
                    findings.append(contentsOf: scanMapping(valueNode, path: path, knownKeys: knownHealthcheckKeys))
                case "depends_on":
                    if case .mapping(let dependencies) = valueNode {
                        for (dependency, requirement) in dependencies {
                            guard let dependencyName = dependency.string else { continue }
                            findings.append(contentsOf: scanMapping(
                                requirement,
                                path: "\(path).\(dependencyName)",
                                knownKeys: knownDependencyKeys
                            ))
                        }
                    }
                case "ports":
                    findings.append(contentsOf: scanSequenceMappings(valueNode, path: path, knownKeys: knownPortKeys))
                case "volumes":
                    findings.append(contentsOf: scanSequenceMappings(valueNode, path: path, knownKeys: knownMountKeys))
                case "networks":
                    if case .mapping(let networks) = valueNode {
                        for (network, attachment) in networks {
                            guard let networkName = network.string else { continue }
                            findings.append(contentsOf: scanMapping(
                                attachment,
                                path: "\(path).\(networkName)",
                                knownKeys: []
                            ))
                        }
                    }
                default:
                    break
                }
            }
        }
        return findings
    }

    private static func scanNamedResources(
        _ resources: Yams.Node.Mapping,
        root: String,
        knownKeys: Set<String>
    ) -> [SupportReport.Finding] {
        Array(resources).flatMap { (pair: (key: Node, value: Node)) -> [SupportReport.Finding] in
            let (nameNode, valueNode) = pair
            guard let name = nameNode.string else { return [] }
            return scanMapping(valueNode, path: "\(root).\(name)", knownKeys: knownKeys)
        }
    }

    private static func scanSequenceMappings(
        _ node: Node,
        path: String,
        knownKeys: Set<String>
    ) -> [SupportReport.Finding] {
        guard case .sequence(let entries) = node else { return [] }
        return entries.enumerated().flatMap { index, entry in
            scanMapping(entry, path: "\(path)[\(index)]", knownKeys: knownKeys)
        }
    }

    private static func scanMapping(
        _ node: Node,
        path: String,
        knownKeys: Set<String>
    ) -> [SupportReport.Finding] {
        guard case .mapping(let mapping) = node else { return [] }
        return mapping.compactMap { keyNode, _ in
            guard let key = keyNode.string, !knownKeys.contains(key) else { return nil }
            return SupportReport.Finding(
                path: "\(path).\(key)",
                message: "unsupported key (ignored)",
                severity: .warning
            )
        }
    }
}
