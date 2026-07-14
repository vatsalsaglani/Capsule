import Foundation

public enum ProjectStoreError: Error, Sendable, Equatable {
    case unsupportedSchema(file: String, found: Int, supported: Int)
    case invalidPathComponent(field: String, value: String)
    case destinationOutsideProjectsRoot(path: String)
    case mismatchedProjectID(expected: String, found: String)
}

extension ProjectStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let file, let found, let supported):
            return "\(file) uses schema version \(found); this Capsule build supports version \(supported)."
        case .invalidPathComponent(let field, let value):
            return "Invalid \(field) `\(value)`: values must be one non-traversing path component."
        case .destinationOutsideProjectsRoot(let path):
            return "Refusing to access a project destination outside the projects directory: \(path)"
        case .mismatchedProjectID(let expected, let found):
            return "project.json is stored under `\(expected)` but declares project id `\(found)`."
        }
    }
}

/// One compose project as Capsule tracks it on disk. Schemas are versioned
/// from day one; bump `schemaVersion` on breaking layout changes and migrate
/// explicitly (plan §4.7).
public struct ProjectRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var sourcePath: String
    public var environmentFilePaths: [String]
    public var projectNameOverride: String?
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        sourcePath: String,
        environmentFilePaths: [String] = [],
        projectNameOverride: String? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.environmentFilePaths = environmentFilePaths
        self.projectNameOverride = projectNameOverride
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, sourcePath, environmentFilePaths, projectNameOverride, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        environmentFilePaths = try container.decodeIfPresent([String].self, forKey: .environmentFilePaths) ?? []
        projectNameOverride = try container.decodeIfPresent(String.self, forKey: .projectNameOverride)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Durable desired state used by ComposeRuntime and Supervisor. This target
/// deliberately owns only serializable state, not orchestration behavior, so
/// the same file can be consumed by the future `capsuled` LaunchAgent.
public struct StoredProjectState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var revision: String
    public var desiredRunning: Bool
    public var serviceConfigHashes: [String: String]
    public var services: [String: StoredServiceState]
    public var updatedAt: Date

    public init(
        revision: String,
        desiredRunning: Bool,
        serviceConfigHashes: [String: String],
        services: [String: StoredServiceState] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.desiredRunning = desiredRunning
        self.serviceConfigHashes = serviceConfigHashes
        self.services = services
        self.updatedAt = updatedAt
    }
}

public struct StoredServiceState: Codable, Sendable, Equatable {
    public var containerID: String?
    public var desiredRunning: Bool
    public var stoppedByUser: Bool
    public var healthObservation: StoredHealthObservation?
    public var restart: StoredRestartState

    public init(
        containerID: String? = nil,
        desiredRunning: Bool,
        stoppedByUser: Bool = false,
        health: StoredHealthState? = nil,
        restartAttempts: Int = 0,
        healthObservation: StoredHealthObservation? = nil,
        restart: StoredRestartState? = nil
    ) {
        self.containerID = containerID
        self.desiredRunning = desiredRunning
        self.stoppedByUser = stoppedByUser
        self.healthObservation = healthObservation ?? health.map {
            StoredHealthObservation(
                state: $0,
                attempt: 0,
                output: "",
                observedAt: Date(timeIntervalSince1970: 0)
            )
        }
        self.restart = restart ?? StoredRestartState(attempts: restartAttempts)
    }

    /// Compatibility projection used by status renderers while the richer
    /// observation remains the durable source of truth.
    public var health: StoredHealthState? {
        get { healthObservation?.state }
        set {
            guard let newValue else {
                healthObservation = nil
                return
            }
            healthObservation = StoredHealthObservation(
                state: newValue,
                attempt: healthObservation?.attempt ?? 0,
                output: healthObservation?.output ?? "",
                observedAt: healthObservation?.observedAt ?? .now
            )
        }
    }

    /// Compatibility projection for existing callers and fixtures. New
    /// supervision code persists the complete restart checkpoint.
    public var restartAttempts: Int {
        get { restart.attempts }
        set { restart.attempts = newValue }
    }
}

public enum StoredHealthState: String, Codable, Sendable, Equatable, Hashable {
    case starting
    case healthy
    case unhealthy
}

public struct StoredHealthObservation: Codable, Sendable, Equatable, Hashable {
    public var state: StoredHealthState
    public var attempt: Int
    public var output: String
    public var observedAt: Date

    public init(state: StoredHealthState, attempt: Int, output: String, observedAt: Date) {
        self.state = state
        self.attempt = attempt
        self.output = output
        self.observedAt = observedAt
    }
}

public enum StoredRestartLimitation: String, Codable, Sendable, Equatable, Hashable {
    case exitStatusUnavailable
    case retryBudgetExhausted
}

public struct StoredRestartState: Codable, Sendable, Equatable, Hashable {
    public var attempts: Int
    public var scheduledFor: Date?
    public var scheduledContainerID: String?
    public var lastError: String?
    public var limitation: StoredRestartLimitation?

    public init(
        attempts: Int = 0,
        scheduledFor: Date? = nil,
        scheduledContainerID: String? = nil,
        lastError: String? = nil,
        limitation: StoredRestartLimitation? = nil
    ) {
        self.attempts = attempts
        self.scheduledFor = scheduledFor
        self.scheduledContainerID = scheduledContainerID
        self.lastError = lastError
        self.limitation = limitation
    }
}

/// JSON-on-disk state under ~/Library/Application Support/Capsule/
/// (plan §4.7). Atomic writes only; SQLite/GRDB only if log indexing ever
/// demands it.
public struct ProjectStore: Sendable {
    private static let resolvedProjectSchemaVersion = 1

    /// Per-service spool rotation defaults: 1 MiB active file plus three
    /// numbered backups (newest is `.1`). Tests may inject smaller limits.
    public static let defaultMaxLogFileBytes = 1_048_576
    public static let defaultLogBackupCount = 3

    public let rootDirectory: URL
    public let maxLogFileBytes: Int
    public let logBackupCount: Int

    public init(
        rootDirectory: URL? = nil,
        maxLogFileBytes: Int = Self.defaultMaxLogFileBytes,
        logBackupCount: Int = Self.defaultLogBackupCount
    ) {
        self.rootDirectory = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Capsule", directoryHint: .isDirectory)
        self.maxLogFileBytes = max(maxLogFileBytes, 1)
        self.logBackupCount = max(logBackupCount, 0)
    }

    public var projectsDirectory: URL {
        rootDirectory.appending(path: "projects", directoryHint: .isDirectory)
    }

    public func projectDirectory(id: String) throws -> URL {
        try validatedDestination(projectID: id)
    }

    public func saveProject(_ record: ProjectRecord) throws {
        try Self.validatePathComponent(record.name, field: "project name")
        let directory = try projectDirectory(id: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeJSON(record, to: directory.appending(path: "project.json"))
    }

    public func loadProject(id: String) throws -> ProjectRecord {
        let url = try validatedDestination(projectID: id, components: ["project.json"])
        let record = try Self.readJSON(ProjectRecord.self, from: url)
        guard record.schemaVersion == ProjectRecord.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchema(
                file: url.lastPathComponent,
                found: record.schemaVersion,
                supported: ProjectRecord.currentSchemaVersion
            )
        }
        guard record.id == id else {
            throw ProjectStoreError.mismatchedProjectID(expected: id, found: record.id)
        }
        try Self.validatePathComponent(record.id, field: "project id")
        try Self.validatePathComponent(record.name, field: "project name")
        return record
    }

    public func deleteProject(id: String) throws {
        let directory = try projectDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func listProjects() throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: projectsDirectory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        )
        return try entries
            .filter(\.hasDirectoryPath)
            .map { try loadProject(id: $0.lastPathComponent) }
            .sorted { $0.name < $1.name }
    }

    /// Persists the fully resolved compose value and support report envelope.
    /// The generic payload keeps ProjectStore UI-free and avoids a dependency
    /// cycle while still guaranteeing the required file name and atomic write.
    public func saveResolvedProject<Value: Encodable>(
        _ value: Value,
        projectID: String
    ) throws {
        let directory = try projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeJSON(
            ResolvedProjectEncodingEnvelope(
                schemaVersion: Self.resolvedProjectSchemaVersion,
                value: value
            ),
            to: directory.appending(path: "resolved-compose.json")
        )
    }

    public func loadResolvedProject<Value: Decodable>(
        _ type: Value.Type,
        projectID: String
    ) throws -> Value {
        let url = try validatedDestination(
            projectID: projectID,
            components: ["resolved-compose.json"]
        )
        let data = try Data(contentsOf: url)
        let header = try Self.decodeJSON(SchemaHeader.self, from: data)
        guard header.schemaVersion == Self.resolvedProjectSchemaVersion else {
            throw ProjectStoreError.unsupportedSchema(
                file: url.lastPathComponent,
                found: header.schemaVersion,
                supported: Self.resolvedProjectSchemaVersion
            )
        }
        return try Self.decodeJSON(
            ResolvedProjectDecodingEnvelope<Value>.self,
            from: data
        ).value
    }

    public func saveState(_ state: StoredProjectState, projectID: String) throws {
        let directory = try projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeJSON(state, to: directory.appending(path: "state.json"))
    }

    public func loadState(projectID: String) throws -> StoredProjectState {
        let url = try validatedDestination(projectID: projectID, components: ["state.json"])
        let data = try Data(contentsOf: url)
        let header = try Self.decodeJSON(SchemaHeader.self, from: data)
        switch header.schemaVersion {
        case StoredProjectState.currentSchemaVersion:
            return try Self.decodeJSON(StoredProjectState.self, from: data)
        case 1:
            let legacy = try Self.decodeJSON(LegacyStoredProjectStateV1.self, from: data)
            let migrated = legacy.migrated()
            // Migration is explicit and atomic. A successful legacy decode is
            // rewritten only after the complete v2 value has been constructed.
            try saveState(migrated, projectID: projectID)
            return migrated
        default:
            throw ProjectStoreError.unsupportedSchema(
                file: url.lastPathComponent,
                found: header.schemaVersion,
                supported: StoredProjectState.currentSchemaVersion
            )
        }
    }

    public func logsDirectory(projectID: String) throws -> URL {
        try validatedDestination(projectID: projectID, components: ["logs"])
    }

    public func logFile(projectID: String, service: String) throws -> URL {
        try Self.validatePathComponent(service, field: "service name")
        return try validatedDestination(
            projectID: projectID,
            components: ["logs", "\(service).log"]
        )
    }

    /// Atomic log-spool update. Project logs are deliberately plain UTF-8 so
    /// users can inspect or recover them without Capsule.
    public func appendLogLine(_ line: String, projectID: String, service: String) throws {
        let directory = try logsDirectory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try logFile(projectID: projectID, service: service)
        var lineData = Data(line.utf8)
        lineData.append(0x0A)
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count + lineData.count > maxLogFileBytes {
            try rotateLogFiles(projectID: projectID, service: service, active: url)
            data = Data()
        }
        // A single pathological line cannot be split without changing the
        // plain line-oriented format; retain its tail and keep the file bound.
        if lineData.count > maxLogFileBytes {
            lineData = Data(lineData.suffix(maxLogFileBytes))
        }
        data.append(lineData)
        try data.write(to: url, options: .atomic)
    }

    private func rotateLogFiles(projectID: String, service: String, active: URL) throws {
        let fileManager = FileManager.default
        guard logBackupCount > 0 else {
            try? fileManager.removeItem(at: active)
            return
        }
        for index in stride(from: logBackupCount, through: 1, by: -1) {
            let destination = try validatedDestination(
                projectID: projectID,
                components: ["logs", "\(service).log.\(index)"]
            )
            try? fileManager.removeItem(at: destination)
            let source = index == 1
                ? active
                : try validatedDestination(
                    projectID: projectID,
                    components: ["logs", "\(service).log.\(index - 1)"]
                )
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(value)).write(to: url, options: .atomic)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decodeJSON(type, from: Data(contentsOf: url))
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func validatedDestination(
        projectID: String,
        components: [String] = []
    ) throws -> URL {
        try Self.validatePathComponent(projectID, field: "project id")
        for component in components {
            try Self.validatePathComponent(component, field: "project path component")
        }

        let root = projectsDirectory.standardizedFileURL
        let destination = components.reduce(
            root.appending(path: projectID, directoryHint: .isDirectory)
        ) { partial, component in
            partial.appending(path: component)
        }.standardizedFileURL

        guard Self.isDescendant(destination, of: root) else {
            throw ProjectStoreError.destinationOutsideProjectsRoot(path: destination.path)
        }

        // Standardization blocks lexical traversal. Resolving symlinks as a
        // second check also prevents an existing project-directory symlink
        // from redirecting persistence outside Capsule's projects root.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedDestination = destination.resolvingSymlinksInPath()
        guard Self.isDescendant(resolvedDestination, of: resolvedRoot) else {
            throw ProjectStoreError.destinationOutsideProjectsRoot(path: resolvedDestination.path)
        }
        return destination
    }

    private static func validatePathComponent(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0")
        else {
            throw ProjectStoreError.invalidPathComponent(field: field, value: value)
        }
    }

    private static func isDescendant(_ destination: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let destinationComponents = destination.pathComponents
        return destinationComponents.count > rootComponents.count
            && destinationComponents.starts(with: rootComponents)
    }
}

/// Serializes read-modify-write access to `state.json` inside one frontend.
/// Atomic replacement prevents torn files; this actor additionally prevents
/// logically concurrent health, restart, and user-intent updates from losing
/// one another at suspension points.
public actor ProjectStateCoordinator {
    private let store: ProjectStore

    public init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    public func load(projectID: String) throws -> StoredProjectState {
        try store.loadState(projectID: projectID)
    }

    @discardableResult
    public func update(
        projectID: String,
        initial: StoredProjectState,
        _ mutate: @Sendable (inout StoredProjectState) -> Void
    ) throws -> StoredProjectState {
        var state = (try? store.loadState(projectID: projectID)) ?? initial
        mutate(&state)
        state.schemaVersion = StoredProjectState.currentSchemaVersion
        state.updatedAt = .now
        try store.saveState(state, projectID: projectID)
        return state
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}

private struct LegacyStoredProjectStateV1: Decodable {
    let schemaVersion: Int
    let revision: String
    let desiredRunning: Bool
    let serviceConfigHashes: [String: String]
    let services: [String: LegacyStoredServiceStateV1]
    let updatedAt: Date

    func migrated() -> StoredProjectState {
        StoredProjectState(
            revision: revision,
            desiredRunning: desiredRunning,
            serviceConfigHashes: serviceConfigHashes,
            services: services.mapValues { service in
                StoredServiceState(
                    containerID: service.containerID,
                    desiredRunning: service.desiredRunning,
                    stoppedByUser: service.stoppedByUser,
                    healthObservation: service.health.map {
                        StoredHealthObservation(
                            state: $0,
                            attempt: 0,
                            output: "",
                            observedAt: updatedAt
                        )
                    },
                    restart: StoredRestartState(attempts: service.restartAttempts)
                )
            },
            updatedAt: updatedAt
        )
    }
}

private struct LegacyStoredServiceStateV1: Decodable {
    let containerID: String?
    let desiredRunning: Bool
    let stoppedByUser: Bool
    let health: StoredHealthState?
    let restartAttempts: Int

    private enum CodingKeys: String, CodingKey {
        case containerID, desiredRunning, stoppedByUser, health, restartAttempts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containerID = try container.decodeIfPresent(String.self, forKey: .containerID)
        desiredRunning = try container.decode(Bool.self, forKey: .desiredRunning)
        stoppedByUser = try container.decodeIfPresent(Bool.self, forKey: .stoppedByUser) ?? false
        health = try container.decodeIfPresent(StoredHealthState.self, forKey: .health)
        restartAttempts = try container.decodeIfPresent(Int.self, forKey: .restartAttempts) ?? 0
    }
}

private struct ResolvedProjectEncodingEnvelope<Value: Encodable>: Encodable {
    let schemaVersion: Int
    let value: Value
}

private struct ResolvedProjectDecodingEnvelope<Value: Decodable>: Decodable {
    let schemaVersion: Int
    let value: Value
}
