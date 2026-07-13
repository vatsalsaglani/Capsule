import Foundation
import ProjectStore
import Testing

@Test func projectStorePersistsResolvedStateAndLogsAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectStore(rootDirectory: root)
    let record = ProjectRecord(
        id: "payments",
        name: "payments",
        sourcePath: "/tmp/payments/compose.yaml",
        environmentFilePaths: ["/tmp/payments/.env.local"],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try store.saveProject(record)
    #expect(try store.loadProject(id: "payments") == record)

    let resolved = ["project": "payments", "support": "all keys recognized"]
    try store.saveResolvedProject(resolved, projectID: "payments")
    #expect(
        try store.loadResolvedProject([String: String].self, projectID: "payments") == resolved
    )

    let state = StoredProjectState(
        revision: "abc123",
        desiredRunning: true,
        serviceConfigHashes: ["api": "hash-api"],
        services: [
            "api": StoredServiceState(
                containerID: "payments-api-1",
                desiredRunning: true,
                health: .healthy
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    try store.saveState(state, projectID: "payments")
    #expect(try store.loadState(projectID: "payments") == state)

    try store.appendLogLine("first", projectID: "payments", service: "api")
    try store.appendLogLine("second", projectID: "payments", service: "api")
    let log = try String(
        contentsOf: store.logFile(projectID: "payments", service: "api"),
        encoding: .utf8
    )
    #expect(log == "first\nsecond\n")
}

@Test func oldProjectRecordWithoutEnvironmentFilesMigratesAdditively() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "id": "legacy",
          "name": "legacy",
          "sourcePath": "/tmp/compose.yaml",
          "createdAt": "2023-11-14T22:13:20Z"
        }
        """.utf8
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(ProjectRecord.self, from: data)
    #expect(record.environmentFilePaths == [])
    #expect(record.projectNameOverride == nil)
}

@Test func projectLogsRotateAtDeterministicBoundWithNumberedBackups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root, maxLogFileBytes: 12, logBackupCount: 2)

    for line in ["aaaaaa", "bbbbbb", "cccccc", "dddddd"] {
        try store.appendLogLine(line, projectID: "demo", service: "api")
    }
    let active = try store.logFile(projectID: "demo", service: "api")
    let directory = try store.logsDirectory(projectID: "demo")
    #expect(try String(contentsOf: active, encoding: .utf8) == "dddddd\n")
    #expect(try String(contentsOf: directory.appendingPathComponent("api.log.1"), encoding: .utf8) == "cccccc\n")
    #expect(try String(contentsOf: directory.appendingPathComponent("api.log.2"), encoding: .utf8) == "bbbbbb\n")
    #expect((try Data(contentsOf: active)).count <= 12)
}

@Test func projectStoreRejectsUnknownStateSchemaInsteadOfGuessingMigration() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root)
    let state = StoredProjectState(
        revision: "future",
        desiredRunning: true,
        serviceConfigHashes: [:]
    )
    try store.saveState(state, projectID: "future")

    let url = try store.projectDirectory(id: "future").appending(path: "state.json")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    object["schemaVersion"] = 999
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

    #expect(throws: ProjectStoreError.self) {
        _ = try store.loadState(projectID: "future")
    }
}

@Test func projectStoreMigratesV1SupervisionStateToStructuredV2Checkpoints() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root)
    let directory = try store.projectDirectory(id: "legacy")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stateURL = directory.appending(path: "state.json")
    try Data(
        """
        {
          "schemaVersion": 1,
          "revision": "legacy-revision",
          "desiredRunning": true,
          "serviceConfigHashes": { "api": "hash-api" },
          "services": {
            "api": {
              "containerID": "legacy-api-1",
              "desiredRunning": true,
              "stoppedByUser": true,
              "health": "unhealthy",
              "restartAttempts": 4
            }
          },
          "updatedAt": "2023-11-14T22:13:20Z"
        }
        """.utf8
    ).write(to: stateURL, options: .atomic)

    let migrated = try store.loadState(projectID: "legacy")
    let service = try #require(migrated.services["api"])
    #expect(migrated.schemaVersion == 2)
    #expect(service.containerID == "legacy-api-1")
    #expect(service.desiredRunning)
    #expect(service.stoppedByUser)
    #expect(service.healthObservation == StoredHealthObservation(
        state: .unhealthy,
        attempt: 0,
        output: "",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    #expect(service.restart == StoredRestartState(attempts: 4))

    let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    #expect(rewritten?["schemaVersion"] as? Int == 2)
    let rewrittenServices = rewritten?["services"] as? [String: Any]
    let rewrittenAPI = rewrittenServices?["api"] as? [String: Any]
    #expect(rewrittenAPI?["healthObservation"] != nil)
    #expect(rewrittenAPI?["restart"] != nil)
    #expect(rewrittenAPI?["health"] == nil)
    #expect(rewrittenAPI?["restartAttempts"] == nil)
}

@Test func projectStoreRejectsTraversalAndSymlinkEscapes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let outside = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let store = ProjectStore(rootDirectory: root)

    for invalidID in ["", ".", "..", "../escape", "nested/project", "nested\\project"] {
        #expect(throws: ProjectStoreError.self) {
            _ = try store.projectDirectory(id: invalidID)
        }
    }
    #expect(throws: ProjectStoreError.self) {
        try store.saveProject(ProjectRecord(
            id: "safe",
            name: "../unsafe",
            sourcePath: "/tmp/compose.yaml",
            createdAt: Date()
        ))
    }
    #expect(throws: ProjectStoreError.self) {
        try store.appendLogLine("escape", projectID: "safe", service: "../../outside")
    }

    try FileManager.default.createDirectory(at: store.projectsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let symlink = store.projectsDirectory.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    #expect(throws: ProjectStoreError.self) {
        try store.saveState(
            StoredProjectState(revision: "unsafe", desiredRunning: true, serviceConfigHashes: [:]),
            projectID: "linked"
        )
    }
}

@Test func resolvedComposeEnvelopeIsVersionedAndValidated() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root)
    try store.saveResolvedProject(["project": "safe"], projectID: "safe")

    let url = try store.projectDirectory(id: "safe").appending(path: "resolved-compose.json")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == 1)
    #expect((object["value"] as? [String: String])?["project"] == "safe")

    object["schemaVersion"] = 999
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    #expect(throws: ProjectStoreError.unsupportedSchema(
        file: "resolved-compose.json",
        found: 999,
        supported: 1
    )) {
        _ = try store.loadResolvedProject([String: String].self, projectID: "safe")
    }
}

@Test func listProjectsUsesTheSameSchemaValidationAsDirectLoads() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectStore(rootDirectory: root)
    try store.saveProject(ProjectRecord(
        id: "future",
        name: "future",
        sourcePath: "/tmp/compose.yaml",
        createdAt: Date()
    ))
    let url = try store.projectDirectory(id: "future").appending(path: "project.json")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    object["schemaVersion"] = 999
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

    #expect(throws: ProjectStoreError.unsupportedSchema(
        file: "project.json",
        found: 999,
        supported: 1
    )) {
        _ = try store.listProjects()
    }
}
