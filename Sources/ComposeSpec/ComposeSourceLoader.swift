import Foundation

public enum ComposeSourceLoader {
    /// Captures every file-backed input needed to resolve a Compose project.
    /// Frontends call this once; parsing and precedence remain in ComposeSpec.
    public static func load(
        fileURL: URL,
        projectName: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        environmentFileURL: URL? = nil
    ) throws -> ComposeSource {
        let fileManager = FileManager.default
        let fileURL = fileURL.standardizedFileURL
        let directory = fileURL.deletingLastPathComponent()
        let yaml = try String(contentsOf: fileURL, encoding: .utf8)
        let dotEnvURL = directory.appendingPathComponent(".env")
        let dotEnv = fileManager.fileExists(atPath: dotEnvURL.path)
            ? try String(contentsOf: dotEnvURL, encoding: .utf8)
            : nil
        let environmentFile = try environmentFileURL.map {
            try String(contentsOf: $0.standardizedFileURL, encoding: .utf8)
        }
        let environmentFilePaths = environmentFileURL.map { [$0.standardizedFileURL.path] } ?? []

        var source = ComposeSource(
            yaml: yaml,
            projectName: projectName,
            fallbackName: directory.lastPathComponent,
            workingDirectory: directory.path,
            filePath: fileURL.path,
            environment: environment,
            dotEnv: dotEnv,
            environmentFile: environmentFile,
            environmentFilePaths: environmentFilePaths
        )
        let preliminary = try ComposeParser().parse(source: source)
        let paths = Set(preliminary.file.services.values.flatMap { $0.envFile?.values ?? [] })
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) {
                source.serviceEnvironmentFiles[path] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return source
    }
}
