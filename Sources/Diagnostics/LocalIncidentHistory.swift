import Foundation

public enum DiagnosticSurface: String, Codable, Sendable, CaseIterable {
    case app
    case cli
}

public enum DiagnosticComponent: String, Codable, Sendable, CaseIterable {
    case application
    case runtime
    case containers
    case compose
    case supervisor
}

/// Product-owned allowlist. The history API deliberately accepts no freeform
/// operation string, arbitrary Error, stderr, argv, path, or resource name.
public enum DiagnosticOperation: String, Codable, Sendable, CaseIterable {
    case launch
    case runtimeDiscovery
    case runtimeVersion
    case runtimeStatus
    case runtimeUpdate
    case containerOperation
    case composeOperation
    case supervision
}

public enum DiagnosticIncidentKind: String, Codable, Sendable, CaseIterable {
    case uncleanTermination
    case binaryMissing
    case unsupportedRuntime
    case runtimeUnavailable
    case commandFailed
    case decodingFailed
    case networkUnavailable
    case persistenceFailed
    case unexpectedFailure
}

public enum DiagnosticIncidentSeverity: String, Codable, Sendable {
    case information
    case warning
    case error
}

public struct DiagnosticIncidentInput: Codable, Sendable, Equatable {
    public let surface: DiagnosticSurface
    public let component: DiagnosticComponent
    public let operation: DiagnosticOperation
    public let kind: DiagnosticIncidentKind
    public let severity: DiagnosticIncidentSeverity
    public let numericCode: Int32?
    public let productVersion: String?
    public let productBuild: String?

    public init(
        surface: DiagnosticSurface,
        component: DiagnosticComponent,
        operation: DiagnosticOperation,
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity,
        numericCode: Int32? = nil,
        productVersion: String? = nil,
        productBuild: String? = nil
    ) {
        self.surface = surface
        self.component = component
        self.operation = operation
        self.kind = kind
        self.severity = severity
        self.numericCode = numericCode
        self.productVersion = productVersion
        self.productBuild = productBuild
    }
}

public struct LocalDiagnosticRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let surface: DiagnosticSurface
    public let component: DiagnosticComponent
    public let operation: DiagnosticOperation
    public let kind: DiagnosticIncidentKind
    public let severity: DiagnosticIncidentSeverity
    public let numericCode: Int32?
    public let productVersion: String?
    public let productBuild: String?
}

public struct DiagnosticHistoryPage: Sendable, Equatable {
    public let records: [LocalDiagnosticRecord]
    public let totalCount: Int
    public let omittedCount: Int

    public init(records: [LocalDiagnosticRecord], totalCount: Int, omittedCount: Int) {
        self.records = records
        self.totalCount = totalCount
        self.omittedCount = omittedCount
    }
}

public struct DiagnosticExport: Sendable, Equatable {
    public let data: Data
    public let suggestedFilename: String
    public let mediaType: String

    public init(data: Data, suggestedFilename: String, mediaType: String) {
        self.data = data
        self.suggestedFilename = suggestedFilename
        self.mediaType = mediaType
    }
}

public struct DiagnosticIncidentRetention: Sendable, Equatable {
    public let maximumRecords: Int
    public let maximumAgeDays: Int
    public let maximumEncodedBytes: Int

    public init(
        maximumRecords: Int = 200,
        maximumAgeDays: Int = 30,
        maximumEncodedBytes: Int = 1_048_576
    ) {
        self.maximumRecords = max(1, maximumRecords)
        self.maximumAgeDays = max(1, maximumAgeDays)
        self.maximumEncodedBytes = max(1_024, maximumEncodedBytes)
    }
}

public struct ApplicationLaunchToken: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
}

public struct ApplicationLaunchReceipt: Sendable, Equatable {
    public let token: ApplicationLaunchToken
    /// Present when an older launch marker was recovered. This means the
    /// prior process did not terminate cleanly; it cannot distinguish crash,
    /// force quit, SIGKILL, power loss, or a machine shutdown.
    public let recoveredUncleanTermination: LocalDiagnosticRecord?
}

public protocol IncidentHistoryServing: Sendable {
    func beginLaunch(
        surface: DiagnosticSurface,
        productVersion: String?,
        productBuild: String?
    ) async throws -> ApplicationLaunchReceipt
    func finishLaunch(_ token: ApplicationLaunchToken) async throws -> Bool
    func record(_ input: DiagnosticIncidentInput) async throws -> LocalDiagnosticRecord
    func history(limit: Int) async throws -> DiagnosticHistoryPage
    func makeExport(limit: Int) async throws -> DiagnosticExport
    func removeAll() async throws
}

/// Privacy-preserving, local-only incident history. The stored schema has no
/// fields capable of containing stderr, argv, environment variables, Compose
/// source, container/image/project names, paths, usernames, or backtraces.
/// There is intentionally no network or upload API in this target.
public actor LocalIncidentHistory: IncidentHistoryServing {
    private struct Envelope: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var records: [LocalDiagnosticRecord]
    }

    private struct LaunchMarker: Codable {
        let id: UUID
        let beganAt: Date
        let surface: DiagnosticSurface
        let productVersion: String?
        let productBuild: String?
    }

    private let rootDirectory: URL
    private let retention: DiagnosticIncidentRetention
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectory: URL? = nil,
        retention: DiagnosticIncidentRetention = .init()
    ) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootDirectory = rootDirectory
            ?? applicationSupport.appendingPathComponent("Capsule/Diagnostics", isDirectory: true)
        self.retention = retention
        self.fileManager = .default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func beginLaunch(
        surface: DiagnosticSurface,
        productVersion: String? = nil,
        productBuild: String? = nil
    ) throws -> ApplicationLaunchReceipt {
        try ensureDirectory()
        var envelope = try loadEnvelope()
        var recovered: LocalDiagnosticRecord?

        if let prior = try loadMarker(), !envelope.records.contains(where: { $0.id == prior.id }) {
            let record = LocalDiagnosticRecord(
                id: prior.id,
                occurredAt: prior.beganAt,
                surface: prior.surface,
                component: .application,
                operation: .launch,
                kind: .uncleanTermination,
                severity: .warning,
                numericCode: nil,
                productVersion: prior.productVersion,
                productBuild: prior.productBuild
            )
            envelope.records.append(record)
            envelope = try pruned(envelope)
            try saveEnvelope(envelope)
            recovered = record
        }

        let token = ApplicationLaunchToken(id: UUID())
        let marker = LaunchMarker(
            id: token.id,
            beganAt: Date(),
            surface: surface,
            productVersion: productVersion,
            productBuild: productBuild
        )
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
        return ApplicationLaunchReceipt(token: token, recoveredUncleanTermination: recovered)
    }

    public func finishLaunch(_ token: ApplicationLaunchToken) throws -> Bool {
        guard let marker = try loadMarker(), marker.id == token.id else { return false }
        try fileManager.removeItem(at: markerURL)
        return true
    }

    @discardableResult
    public func record(_ input: DiagnosticIncidentInput) throws -> LocalDiagnosticRecord {
        try ensureDirectory()
        var envelope = try loadEnvelope()
        if let latest = envelope.records.last,
           latest.surface == input.surface,
           latest.component == input.component,
           latest.operation == input.operation,
           latest.kind == input.kind,
           latest.numericCode == input.numericCode,
           Date().timeIntervalSince(latest.occurredAt) < 300 {
            return latest
        }
        let record = LocalDiagnosticRecord(
            id: UUID(),
            occurredAt: Date(),
            surface: input.surface,
            component: input.component,
            operation: input.operation,
            kind: input.kind,
            severity: input.severity,
            numericCode: input.numericCode,
            productVersion: input.productVersion,
            productBuild: input.productBuild
        )
        envelope.records.append(record)
        envelope = try pruned(envelope)
        try saveEnvelope(envelope)
        return record
    }

    public func history(limit: Int = 50) throws -> DiagnosticHistoryPage {
        let records = try loadEnvelope().records.sorted { $0.occurredAt > $1.occurredAt }
        let boundedLimit = max(0, min(limit, retention.maximumRecords))
        let visible = Array(records.prefix(boundedLimit))
        return DiagnosticHistoryPage(
            records: visible,
            totalCount: records.count,
            omittedCount: max(0, records.count - visible.count)
        )
    }

    public func makeExport(limit: Int = 200) throws -> DiagnosticExport {
        let page = try history(limit: limit)
        let export = Envelope(
            schemaVersion: Envelope.currentSchemaVersion,
            records: page.records
        )
        return DiagnosticExport(
            data: try encoder.encode(export),
            suggestedFilename: "capsule-diagnostics.json",
            mediaType: "application/json"
        )
    }

    public func removeAll() throws {
        if fileManager.fileExists(atPath: historyURL.path) {
            try fileManager.removeItem(at: historyURL)
        }
    }

    private var historyURL: URL { rootDirectory.appendingPathComponent("history.json") }
    private var markerURL: URL { rootDirectory.appendingPathComponent("launch.json") }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func loadMarker() throws -> LaunchMarker? {
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        return try decoder.decode(LaunchMarker.self, from: Data(contentsOf: markerURL))
    }

    private func loadEnvelope() throws -> Envelope {
        guard fileManager.fileExists(atPath: historyURL.path) else {
            return Envelope(schemaVersion: Envelope.currentSchemaVersion, records: [])
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: historyURL))
            guard envelope.schemaVersion == Envelope.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return envelope
        } catch {
            let quarantine = rootDirectory.appendingPathComponent(
                "history-corrupt-\(Int(Date().timeIntervalSince1970)).json"
            )
            try? fileManager.moveItem(at: historyURL, to: quarantine)
            return Envelope(schemaVersion: Envelope.currentSchemaVersion, records: [])
        }
    }

    private func saveEnvelope(_ envelope: Envelope) throws {
        try ensureDirectory()
        try encoder.encode(envelope).write(to: historyURL, options: .atomic)
    }

    private func pruned(_ source: Envelope) throws -> Envelope {
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -retention.maximumAgeDays,
            to: Date()
        ) ?? .distantPast
        var records = source.records
            .filter { $0.occurredAt >= cutoff }
            .sorted { $0.occurredAt < $1.occurredAt }
        if records.count > retention.maximumRecords {
            records.removeFirst(records.count - retention.maximumRecords)
        }
        var envelope = Envelope(schemaVersion: Envelope.currentSchemaVersion, records: records)
        while records.count > 1, try encoder.encode(envelope).count > retention.maximumEncodedBytes {
            records.removeFirst()
            envelope.records = records
        }
        return envelope
    }
}
