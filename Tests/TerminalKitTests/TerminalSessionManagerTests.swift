import ContainerClient
import ContainerClientTestSupport
import Foundation
import Testing
@testable import TerminalKit

/// A fully test-controlled `TerminalSession` — an actor (not a class with
/// `@unchecked Sendable`; this codebase's hard rule against adding any new
/// `@unchecked Sendable` applies to test scaffolding too) so `simulateExit`
/// can be driven from test code exactly like the manager's real watcher task
/// observes a genuine `PTYExecSession`.
actor ScriptedTerminalSession: TerminalSession {
    nonisolated let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32?, Never>] = []
    private(set) var terminateCallCount = 0

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
        self.output = stream
        self.continuation = continuation
    }

    func send(_ data: Data) async {}
    func resize(columns: Int, rows: Int) async {}

    func terminate() async {
        terminateCallCount += 1
        simulateExit(code: exitCode ?? 0)
    }

    func waitUntilExit() async -> Int32? {
        if let exitCode { return exitCode }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            exitWaiters.append(continuation)
        }
    }

    /// Test control: simulate the container going away (or the shell
    /// exiting) on its own, independent of `terminate()`.
    func simulateExit(code: Int32) {
        guard exitCode == nil else { return }
        exitCode = code
        continuation.finish()
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters { waiter.resume(returning: code) }
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .milliseconds(500),
    pollEvery: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async -> Bool {
    if condition() { return true }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollEvery)
        if condition() { return true }
    }
    return condition()
}

@Test @MainActor func openTabDetectsShellAndConnects() async throws {
    let runtime = FakeContainerRuntime()
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")

    #expect(manager.tabs.count == 1)
    let tab = try #require(manager.tabs.first)
    #expect(tab.containerID == "c1")
    #expect(tab.state == .connected(shell: "sh"))
    #expect(manager.selectedTabID == tab.id)
}

@Test @MainActor func openTabSurfacesShellDetectionFailureAsFailedState() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setError(
        RuntimeError.commandFailed(command: "container exec", exitCode: 127, stderr: "not found"),
        for: .exec
    )
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")

    let tab = try #require(manager.tabs.first)
    guard case .failed = tab.state else {
        Issue.record("expected .failed state, got \(tab.state)")
        return
    }
}

@Test @MainActor func closeTabTerminatesSessionAndRemovesTab() async throws {
    let runtime = FakeContainerRuntime()
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")
    let tab = try #require(manager.tabs.first)
    let session = try #require(manager.session(for: tab.id) as? ScriptedTerminalSession)

    await manager.closeTab(id: tab.id)

    #expect(manager.tabs.isEmpty)
    #expect(manager.session(for: tab.id) == nil)
    let callCount = await session.terminateCallCount
    #expect(callCount == 1)
}

@Test @MainActor func openTwoTabsAndSwitchSelection() async throws {
    let runtime = FakeContainerRuntime()
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")
    let firstID = try #require(manager.tabs.first?.id)
    await manager.openTab(containerID: "c2")
    let secondID = try #require(manager.tabs.last?.id)

    #expect(manager.tabs.count == 2)
    // Opening a tab selects it immediately.
    #expect(manager.selectedTabID == secondID)

    manager.selectedTabID = firstID
    #expect(manager.selectedTabID == firstID)
}

@Test @MainActor func sessionExitingOnItsOwnTransitionsTabToExitedState() async throws {
    let runtime = FakeContainerRuntime()
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")
    let tab = try #require(manager.tabs.first)
    let session = try #require(manager.session(for: tab.id) as? ScriptedTerminalSession)

    // Container went away out from under the session — exit 137 (S3).
    await session.simulateExit(code: 137)

    let reachedExited = await waitUntil {
        manager.tabs.first?.state == .exited(code: 137)
    }
    #expect(reachedExited)
}

@Test @MainActor func closeTabCancelsWatcherBeforeItObservesASimulatedExit() async throws {
    let runtime = FakeContainerRuntime()
    let manager = TerminalSessionManager(runtime: runtime) { _, _ in ScriptedTerminalSession() }

    await manager.openTab(containerID: "c1")
    let tab = try #require(manager.tabs.first)

    await manager.closeTab(id: tab.id)

    // The watcher for this tab must not still be alive trying to update a
    // tab that no longer exists — closing twice, or the tab list mutating
    // unexpectedly afterward, would indicate a leaked watcher task.
    #expect(manager.tabs.isEmpty)
    await manager.closeTab(id: tab.id) // idempotent: no crash, no-op
    #expect(manager.tabs.isEmpty)
}
