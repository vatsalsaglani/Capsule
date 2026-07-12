import Foundation

/// One compose project as Capsule tracks it on disk. Schemas are versioned
/// from day one; bump `schemaVersion` on breaking layout changes and migrate
/// explicitly (plan §4.7).
public struct ProjectRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var sourcePath: String
    public var createdAt: Date

    public init(id: String, name: String, sourcePath: String, createdAt: Date) {
        self.schemaVersion = 1
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.createdAt = createdAt
    }
}

/// JSON-on-disk state under ~/Library/Application Support/Capsule/
/// (plan §4.7). Atomic writes only; SQLite/GRDB only if log indexing ever
/// demands it.
public struct ProjectStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Capsule", directoryHint: .isDirectory)
    }

    public var projectsDirectory: URL {
        rootDirectory.appending(path: "projects", directoryHint: .isDirectory)
    }

    public func projectDirectory(id: String) -> URL {
        projectsDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    public func saveProject(_ record: ProjectRecord) throws {
        let directory = projectDirectory(id: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeJSON(record, to: directory.appending(path: "project.json"))
    }

    public func loadProject(id: String) throws -> ProjectRecord {
        let url = projectDirectory(id: id).appending(path: "project.json")
        return try Self.readJSON(ProjectRecord.self, from: url)
    }

    public func listProjects() throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: projectsDirectory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        )
        return try entries
            .filter(\.hasDirectoryPath)
            .map { try Self.readJSON(ProjectRecord.self, from: $0.appending(path: "project.json")) }
            .sorted { $0.name < $1.name }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(value)).write(to: url, options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}
