import Foundation
import Yams

/// Parsed compose file plus everything downstream stages need: resolved
/// project name and the support report (which `up`/`config` must always show).
public struct ComposeDocument: Sendable {
    public let projectName: String
    public let file: ComposeFile
    public let support: SupportReport

    public init(projectName: String, file: ComposeFile, support: SupportReport) {
        self.projectName = projectName
        self.file = file
        self.support = support
    }
}

public struct ComposeParser: Sendable {
    public init() {}

    /// - Parameters:
    ///   - projectName: explicit `-p` override; wins over the file's `name:`.
    ///   - fallbackName: usually the compose file's directory name (plan §4.3).
    public func parse(
        yaml: String,
        projectName: String? = nil,
        fallbackName: String = "default"
    ) throws -> ComposeDocument {
        // NOTE(M2): variable interpolation (Interpolation.swift) and .env
        // loading are applied per YAML scalar before this decode lands here.
        let file = try YAMLDecoder().decode(ComposeFile.self, from: yaml)

        var findings = (try? SupportScanner.scan(yaml: yaml)) ?? []
        for (name, service) in file.services.sorted(by: { $0.key < $1.key }) {
            if service.image == nil && service.build == nil {
                findings.append(.init(
                    path: "services.\(name)",
                    message: "needs either `image` or `build`",
                    severity: .fatal
                ))
            }
        }

        return ComposeDocument(
            projectName: projectName ?? file.name ?? fallbackName,
            file: file,
            support: SupportReport(findings: findings)
        )
    }

    public func parse(fileAt url: URL, projectName: String? = nil) throws -> ComposeDocument {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        return try parse(
            yaml: yaml,
            projectName: projectName,
            fallbackName: url.deletingLastPathComponent().lastPathComponent
        )
    }
}
