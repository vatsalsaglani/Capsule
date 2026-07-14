import Diagnostics
import Foundation
import Testing

private func temporaryDiagnosticsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("capsule-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func incidentHistoryRecoversPriorLaunchAsUncleanTermination() async throws {
    let root = try temporaryDiagnosticsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstStore = LocalIncidentHistory(rootDirectory: root)
    let first = try await firstStore.beginLaunch(
        surface: .app,
        productVersion: "0.0.1",
        productBuild: "1"
    )
    let secondStore = LocalIncidentHistory(rootDirectory: root)
    let second = try await secondStore.beginLaunch(
        surface: .app,
        productVersion: "0.0.1",
        productBuild: "2"
    )

    #expect(first.token != second.token)
    #expect(second.recoveredUncleanTermination?.kind == .uncleanTermination)
    #expect(second.recoveredUncleanTermination?.productBuild == "1")
    #expect(try await secondStore.finishLaunch(second.token))
    #expect(!(try await secondStore.finishLaunch(first.token)))
}

@Test func incidentHistoryIsBoundedAndExportsOnlyStructuredFields() async throws {
    let root = try temporaryDiagnosticsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalIncidentHistory(
        rootDirectory: root,
        retention: .init(maximumRecords: 2, maximumAgeDays: 30, maximumEncodedBytes: 16_384)
    )

    for code in 1...3 {
        _ = try await store.record(.init(
            surface: .cli,
            component: .runtime,
            operation: .runtimeStatus,
            kind: .commandFailed,
            severity: .error,
            numericCode: Int32(code)
        ))
    }

    let page = try await store.history(limit: 50)
    let export = try await store.makeExport(limit: 50)
    let text = String(decoding: export.data, as: UTF8.self)

    #expect(page.totalCount == 2)
    #expect(Set(page.records.compactMap(\.numericCode)) == [2, 3])
    #expect(!text.contains("stderr"))
    #expect(!text.contains("argv"))
    #expect(!text.contains(FileManager.default.homeDirectoryForCurrentUser.path))
}
