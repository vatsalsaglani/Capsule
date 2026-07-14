import ContainerClient
import Foundation

public actor BuildHistoryStore {
    private struct Snapshot: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var records: [BuildRecord]
    }

    public static let maximumRecords = 100
    public static let maximumOutputLines = 500
    public static let maximumLineLength = 4_096

    private let rootDirectory: URL
    private var cached: [BuildRecord]?

    public init(rootDirectory: URL = BuildHistoryStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRootDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Capsule/builds", directoryHint: .isDirectory)
    }

    public func records() throws -> [BuildRecord] {
        try loadIfNeeded()
    }

    public func upsert(_ record: BuildRecord) throws {
        var values = try loadIfNeeded()
        var sanitized = record
        sanitized.output = Array(record.output.suffix(Self.maximumOutputLines)).map { line in
            let message = String(line.message.prefix(Self.maximumLineLength))
            return BuildProgress(message: message, receivedAt: line.receivedAt)
        }
        if let index = values.firstIndex(where: { $0.id == record.id }) {
            values[index] = sanitized
        } else {
            values.append(sanitized)
        }
        values.sort { $0.startedAt > $1.startedAt }
        values = Array(values.prefix(Self.maximumRecords))
        cached = values
        try save(values)
    }

    public func clear() throws {
        cached = []
        try save([])
    }

    private func loadIfNeeded() throws -> [BuildRecord] {
        if let cached { return cached }
        let fileURL = rootDirectory.appending(path: "history.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cached = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder.capsule.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var values = snapshot.records
        var recovered = false
        for index in values.indices where values[index].state == .running {
            values[index].state = .failed
            values[index].finishedAt = Date()
            values[index].failureMessage = "The frontend exited before this build reported completion."
            recovered = true
        }
        cached = values
        if recovered { try save(values) }
        return values
    }

    private func save(_ records: [BuildRecord]) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let snapshot = Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            records: records
        )
        let data = try JSONEncoder.capsule.encode(snapshot)
        try data.write(to: rootDirectory.appending(path: "history.json"), options: .atomic)
    }
}

private extension JSONEncoder {
    static var capsule: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var capsule: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
