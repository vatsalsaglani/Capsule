import Foundation
import Testing
@testable import ContainerClient

// P1A Contract PR: only cliVersion/listContainers/startContainer/
// stopContainer/deleteContainer/systemStatus have real bodies; everything
// else is a `notImplemented` stub until the implementation PR. `binaryPath`
// is never touched by a stub body, so any path works here.
@Test func cliProcessClientNewMethodThrowsNotImplemented() async throws {
    let client = try CLIProcessClient(binaryPath: "/usr/bin/true")

    await #expect(throws: RuntimeError.self) {
        try await client.killContainer(id: "web-1", signal: "SIGTERM")
    }

    do {
        _ = try await client.inspectContainer(id: "web-1")
        Issue.record("expected inspectContainer to throw notImplemented")
    } catch RuntimeError.notImplemented(let operation) {
        #expect(operation == "inspectContainer")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
