import Foundation
import Yams

/// A self-contained, serializable compose input. Capturing environment values
/// here keeps resolution deterministic and prevents planners/stores from
/// reaching into ambient process state later.
public struct ComposeSource: Codable, Sendable, Hashable {
    public var yaml: String
    public var projectName: String?
    public var fallbackName: String
    public var workingDirectory: String
    /// Exact originating file, when the source was loaded from disk. This is
    /// persisted so non-default names such as `stack.prod.yaml` reopen.
    public var filePath: String?
    /// Highest-precedence interpolation environment (normally the invoking
    /// process environment).
    public var environment: [String: String]
    /// Contents of the project-directory `.env`, when present.
    public var dotEnv: String?
    /// Contents supplied by `--env-file`, when present. Its values override
    /// `.env`; `environment` overrides both.
    public var environmentFile: String?
    /// Exact explicit interpolation env-file paths used by the frontend.
    /// Contents remain captured above for deterministic parsing; paths let a
    /// persisted project reload fresh file contents on a later app launch.
    public var environmentFilePaths: [String]
    /// Contents of service-level `env_file` references, keyed by the path as
    /// written in the resolved compose model.
    public var serviceEnvironmentFiles: [String: String]

    public init(
        yaml: String,
        projectName: String? = nil,
        fallbackName: String = "default",
        workingDirectory: String = ".",
        filePath: String? = nil,
        environment: [String: String] = [:],
        dotEnv: String? = nil,
        environmentFile: String? = nil,
        environmentFilePaths: [String] = [],
        serviceEnvironmentFiles: [String: String] = [:]
    ) {
        self.yaml = yaml
        self.projectName = projectName
        self.fallbackName = fallbackName
        self.workingDirectory = workingDirectory
        self.filePath = filePath
        self.environment = environment
        self.dotEnv = dotEnv
        self.environmentFile = environmentFile
        self.environmentFilePaths = environmentFilePaths
        self.serviceEnvironmentFiles = serviceEnvironmentFiles
    }
}

/// Parsed compose file plus everything downstream stages need. The `file`
/// has already been interpolated; `environment` is the exact merged input
/// used during that resolution.
public struct ComposeDocument: Codable, Sendable, Hashable {
    public let projectName: String
    public let file: ComposeFile
    public let support: SupportReport
    public let environment: [String: String]
    public let workingDirectory: String

    public init(
        projectName: String,
        file: ComposeFile,
        support: SupportReport,
        environment: [String: String] = [:],
        workingDirectory: String = "."
    ) {
        self.projectName = projectName
        self.file = file
        self.support = support
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct ComposeParser: Sendable {
    public init() {}

    /// Resolves a self-contained source. Precedence is deterministic:
    /// explicit environment > `--env-file` contents > project `.env`.
    public func parse(source: ComposeSource) throws -> ComposeDocument {
        let dotEnv = EnvironmentFileParser.parse(source.dotEnv, name: ".env")
        let environmentFile = EnvironmentFileParser.parse(source.environmentFile, name: "--env-file")
        var variables = dotEnv.values
            .merging(environmentFile.values) { _, higher in higher }
            .merging(source.environment) { _, higher in higher }
        var environmentInterpolationFindings: [SupportReport.Finding] = []
        // `.env` and `--env-file` values may refer to one another. Resolve to
        // a fixed point while preserving explicit process values as the
        // highest-precedence, immutable layer.
        for _ in 0...variables.count {
            var changed = false
            for key in variables.keys.sorted() where source.environment[key] == nil {
                guard let value = variables[key] else { continue }
                do {
                    let resolved = try Interpolation.interpolate(value, variables: variables)
                    if resolved != value {
                        variables[key] = resolved
                        changed = true
                    }
                } catch let error as Interpolation.MissingVariableError {
                    if !environmentInterpolationFindings.contains(where: { $0.path == "environment.\(key)" }) {
                        environmentInterpolationFindings.append(.init(
                            path: "environment.\(key)",
                            message: "missing interpolation variable `\(error.variable)`: \(error.message)",
                            severity: .fatal
                        ))
                    }
                } catch {
                    if !environmentInterpolationFindings.contains(where: { $0.path == "environment.\(key)" }) {
                        environmentInterpolationFindings.append(.init(
                            path: "environment.\(key)",
                            message: "interpolation failed: \(error)",
                            severity: .fatal
                        ))
                    }
                }
            }
            if !changed { break }
        }

        guard var root = try Yams.compose(yaml: source.yaml) else {
            throw ComposeParseError.emptyDocument
        }

        var findings = SupportScanner.scan(root: root)
        findings.append(contentsOf: dotEnv.findings)
        findings.append(contentsOf: environmentFile.findings)
        findings.append(contentsOf: environmentInterpolationFindings)
        root = interpolate(root, variables: variables, path: [], findings: &findings)

        let resolvedYAML = try Yams.serialize(node: root)
        var file = try YAMLDecoder().decode(ComposeFile.self, from: resolvedYAML)
        resolveServiceEnvironment(
            file: &file,
            source: source,
            variables: variables,
            findings: &findings
        )

        for (name, service) in file.services.sorted(by: { $0.key < $1.key }) {
            if case .onFailure = service.restart {
                findings.append(.init(
                    path: "services.\(name).restart",
                    message: "on-failure is accepted, but Apple container 1.1 does not expose exit status; Capsule pauses this policy and surfaces the limitation instead of guessing",
                    severity: .warning
                ))
            }
            if let grace = service.stopGracePeriod, ComposeDuration.parse(grace) == nil {
                findings.append(.init(
                    path: "services.\(name).stop_grace_period",
                    message: "invalid duration `\(grace)`",
                    severity: .fatal
                ))
            }
            if service.image == nil && service.build == nil {
                findings.append(.init(
                    path: "services.\(name)",
                    message: "needs either `image` or `build`",
                    severity: .fatal
                ))
            }
            for dependency in service.dependsOn?.requirements.keys.sorted() ?? [] {
                if file.services[dependency] == nil {
                    findings.append(.init(
                        path: "services.\(name).depends_on.\(dependency)",
                        message: "references an unknown service",
                        severity: .fatal
                    ))
                } else if service.dependsOn?.requirements[dependency]?.condition == .serviceHealthy,
                          file.services[dependency]?.healthcheck == nil {
                    findings.append(.init(
                        path: "services.\(name).depends_on.\(dependency).condition",
                        message: "service_healthy requires the dependency to define a healthcheck",
                        severity: .fatal
                    ))
                }
            }
            for (index, mount) in (service.volumes ?? []).enumerated()
                where mount.kind == .volume && mount.source != nil {
                if file.namedVolumes[mount.source!] == nil {
                    findings.append(.init(
                        path: "services.\(name).volumes.[\(index)]",
                        message: "named volume `\(mount.source!)` is not declared at top level",
                        severity: .fatal
                    ))
                }
            }
            for network in service.networks?.values ?? []
                where network != "default" && file.namedNetworks[network] == nil {
                findings.append(.init(
                    path: "services.\(name).networks.\(network)",
                    message: "network is not declared at top level",
                    severity: .fatal
                ))
            }
            for (index, port) in (service.ports ?? []).enumerated()
                where port.proto != "tcp" && port.proto != "udp" {
                findings.append(.init(
                    path: "services.\(name).ports.[\(index)].protocol",
                    message: "only tcp and udp are supported",
                    severity: .fatal
                ))
            }
        }

        let projectName = source.projectName ?? file.name ?? source.fallbackName
        guard Self.isSafeProjectName(projectName) else {
            throw ComposeParseError.invalidProjectName(projectName)
        }

        return ComposeDocument(
            projectName: projectName,
            file: file,
            support: SupportReport(findings: findings),
            environment: variables,
            workingDirectory: source.workingDirectory
        )
    }

    /// Compatibility convenience for in-memory callers. Callers that need
    /// interpolation should prefer `parse(source:)` so ambient inputs remain
    /// explicit and serializable.
    public func parse(
        yaml: String,
        projectName: String? = nil,
        fallbackName: String = "default"
    ) throws -> ComposeDocument {
        try parse(source: ComposeSource(
            yaml: yaml,
            projectName: projectName,
            fallbackName: fallbackName
        ))
    }

    /// Loads file-backed inputs once, then delegates to the deterministic
    /// `ComposeSource` path. `environmentFileURL` represents `--env-file`.
    public func parse(
        fileAt url: URL,
        projectName: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        environmentFileURL: URL? = nil
    ) throws -> ComposeDocument {
        try parse(source: ComposeSourceLoader.load(
            fileURL: url,
            projectName: projectName,
            environment: environment,
            environmentFileURL: environmentFileURL
        ))
    }

    private func interpolate(
        _ node: Node,
        variables: [String: String],
        path: [String],
        findings: inout [SupportReport.Finding]
    ) -> Node {
        switch node {
        case .scalar(var scalar):
            do {
                scalar.string = try Interpolation.interpolate(scalar.string, variables: variables)
            } catch let error as Interpolation.MissingVariableError {
                findings.append(.init(
                    path: path.isEmpty ? "$" : path.joined(separator: "."),
                    message: "missing interpolation variable `\(error.variable)`: \(error.message)",
                    severity: .fatal
                ))
            } catch {
                findings.append(.init(
                    path: path.isEmpty ? "$" : path.joined(separator: "."),
                    message: "interpolation failed: \(error)",
                    severity: .fatal
                ))
            }
            return .scalar(scalar)

        case .mapping(var mapping):
            for index in mapping.indices {
                let pair = mapping[index]
                let key = pair.key.string ?? "?"
                mapping[index] = (
                    key: pair.key,
                    value: interpolate(
                        pair.value,
                        variables: variables,
                        path: path + [key],
                        findings: &findings
                    )
                )
            }
            return .mapping(mapping)

        case .sequence(var sequence):
            for index in sequence.indices {
                sequence[index] = interpolate(
                    sequence[index],
                    variables: variables,
                    path: path + ["[\(index)]"],
                    findings: &findings
                )
            }
            return .sequence(sequence)

        case .alias:
            return node
        }
    }

    private func resolveServiceEnvironment(
        file: inout ComposeFile,
        source: ComposeSource,
        variables: [String: String],
        findings: inout [SupportReport.Finding]
    ) {
        for serviceName in file.services.keys.sorted() {
            guard var service = file.services[serviceName] else { continue }
            var merged: [String: String?] = [:]
            for path in service.envFile?.values ?? [] {
                guard let contents = source.serviceEnvironmentFiles[path] else {
                    findings.append(.init(
                        path: "services.\(serviceName).env_file",
                        message: "environment file not found or unreadable: \(path)",
                        severity: .fatal
                    ))
                    continue
                }
                let parsed = EnvironmentFileParser.parse(contents, name: path)
                findings.append(contentsOf: parsed.findings.map { finding in
                    .init(
                        path: "services.\(serviceName).env_file.\(finding.path)",
                        message: finding.message,
                        severity: finding.severity
                    )
                })
                for (key, rawValue) in parsed.values {
                    do {
                        merged[key] = try Interpolation.interpolate(rawValue, variables: variables)
                    } catch let error as Interpolation.MissingVariableError {
                        findings.append(.init(
                            path: "services.\(serviceName).env_file.\(key)",
                            message: "missing interpolation variable `\(error.variable)`: \(error.message)",
                            severity: .fatal
                        ))
                    } catch {
                        findings.append(.init(
                            path: "services.\(serviceName).env_file.\(key)",
                            message: "interpolation failed: \(error)",
                            severity: .fatal
                        ))
                    }
                }
            }
            for (key, value) in service.environment?.entries ?? [:] {
                // Double optional is intentional: a missing host value keeps
                // the pass-through entry as nil instead of silently turning
                // an unset variable into an empty string.
                merged[key] = .some(value ?? variables[key])
            }
            if service.environment != nil || service.envFile != nil {
                service.environment = EnvironmentMap(entries: merged)
            }
            file.services[serviceName] = service
        }
    }

    private static func isSafeProjectName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }
}

public enum ComposeParseError: Error, Equatable, Sendable {
    case emptyDocument
    case invalidProjectName(String)
}

extension ComposeParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The compose document is empty."
        case .invalidProjectName(let name):
            return "Invalid compose project name `\(name)`: names cannot contain path traversal."
        }
    }
}

private enum EnvironmentFileParser {
    struct Result {
        var values: [String: String] = [:]
        var findings: [SupportReport.Finding] = []
    }

    static func parse(_ contents: String?, name: String) -> Result {
        guard let contents else { return Result() }
        var result = Result()
        for (offset, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                result.findings.append(.init(
                    path: "\(name):\(offset + 1)",
                    message: "expected KEY=VALUE",
                    severity: .fatal
                ))
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard isValidName(key) else {
                result.findings.append(.init(
                    path: "\(name):\(offset + 1)",
                    message: "invalid environment variable name `\(key)`",
                    severity: .fatal
                ))
                continue
            }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, value.last == first, first == "\"" || first == "'" {
                value.removeFirst()
                value.removeLast()
                if first == "\"" {
                    value = value
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
            } else if let comment = value.firstIndex(of: "#"),
                      comment > value.startIndex,
                      value[value.index(before: comment)].isWhitespace {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            result.values[key] = value
        }
        return result
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
