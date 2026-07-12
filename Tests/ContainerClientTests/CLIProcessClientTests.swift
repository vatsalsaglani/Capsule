import Foundation
import Testing
@testable import ContainerClient

// P1A implementation PR: every method has a real body now (see
// `ScriptedCLITests` for behavior verified against emulated `container`
// output, and `LiveRuntimeTests` for the env-gated suite against the real
// binary). This file covers `CLIProcessClient`-level concerns that don't
// need a scripted binary at all.

@Test func cliProcessClientInitTrustsAnExplicitBinaryPathWithoutValidatingIt() async throws {
    // An explicit `binaryPath` is stored as-is — existence is only checked
    // when a command actually runs (`Subprocess.run`'s
    // `isExecutableFile` guard), not at init time. `ContainerBinaryLocator
    // .locate()` failing (the `binaryPath: nil` branch) is what produces
    // `RuntimeError.binaryNotFound` — covered by `RuntimeError`'s existing
    // coverage in `ContainerClientTests`; this only pins the explicit-path
    // branch's documented behavior.
    let client = try CLIProcessClient(binaryPath: "/no/such/container/binary")
    #expect(client.binaryPath == "/no/such/container/binary")

    await #expect(throws: SubprocessError.self) {
        _ = try await client.cliVersion()
    }
}

@Test func cliProcessClientInitAcceptsExplicitBinaryPathWithoutTouchingIt() throws {
    // `/usr/bin/true` never gets invoked here — this only exercises the
    // init's "explicit path wins, skip locating" branch.
    let client = try CLIProcessClient(binaryPath: "/usr/bin/true")
    #expect(client.binaryPath == "/usr/bin/true")
    #expect(client.statsInterval == .seconds(2))
}

@Test func cliProcessClientInitAcceptsCustomStatsInterval() throws {
    let client = try CLIProcessClient(binaryPath: "/usr/bin/true", statsInterval: .milliseconds(500))
    #expect(client.statsInterval == .milliseconds(500))
}
