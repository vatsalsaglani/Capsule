import Foundation
import Yams

/// "Fail loud on anything else" (plan §4.2): every key we don't act on is
/// reported, per-key policy warning (ignored) vs fatal.
public struct SupportReport: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case warning
        case fatal
    }

    public struct Finding: Sendable, Equatable {
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

    static func scan(yaml: String) throws -> [SupportReport.Finding] {
        guard let root = try Yams.compose(yaml: yaml),
              case .mapping(let topLevel) = root
        else { return [] }

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
            for (keyNode, _) in body {
                guard let key = keyNode.string, !knownServiceKeys.contains(key) else { continue }
                let message = deferredServiceKeys.contains(key)
                    ? "planned for v1.1+ (ignored for now)"
                    : "unsupported key (ignored)"
                findings.append(.init(
                    path: "services.\(serviceName).\(key)",
                    message: message,
                    severity: .warning
                ))
            }
        }
        return findings
    }
}
