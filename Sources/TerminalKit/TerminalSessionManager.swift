import ContainerClient
import Foundation
import Observation

/// Owns the Terminal screen's tabs (one per open `TerminalSession`), each
/// backed by a shell-detected session into a container. Imports `Observation`
/// only, never SwiftUI — TerminalKit stays UI-free (rule 1/2, AGENTS.md) so
/// the App's `TerminalHostView`/`TerminalTabsView` are the only place
/// SwiftTerm or SwiftUI ever appear.
@MainActor
@Observable
public final class TerminalSessionManager {
    public struct Tab: Identifiable, Sendable {
        public let id: UUID
        public let containerID: String
        public var state: TabState

        init(id: UUID = UUID(), containerID: String, state: TabState) {
            self.id = id
            self.containerID = containerID
            self.state = state
        }
    }

    public enum TabState: Sendable, Equatable {
        case connecting
        case connected(shell: String)
        case exited(code: Int32?)
        case failed(message: String)
    }

    public private(set) var tabs: [Tab] = []
    public var selectedTabID: UUID?

    private let runtime: any ContainerRuntime
    /// Test seam: prod passes a `PTYExecSession`-backed builder
    /// (`PTYExecSession.makeContainerExecFactory`); tests pass scripted
    /// fakes. `@Sendable` since it may run detection/session construction
    /// off the main actor in a future revision; kept synchronous-throwing
    /// today to mirror `PTYExecSession.init`.
    private let makeSession: @Sendable (_ containerID: String, _ shell: String) throws -> any TerminalSession

    private var sessionsByTabID: [UUID: any TerminalSession] = [:]
    /// One watcher per open tab, cancelled on `closeTab` so nothing leaks
    /// past a tab's lifetime (B1-style review point named in the brief).
    private var watchersByTabID: [UUID: Task<Void, Never>] = [:]

    public init(
        runtime: any ContainerRuntime,
        makeSession: @escaping @Sendable (_ containerID: String, _ shell: String) throws -> any TerminalSession
    ) {
        self.runtime = runtime
        self.makeSession = makeSession
    }

    /// Detects a usable shell, spawns a session, and tracks it as a new tab
    /// (selected immediately). Failure at either step surfaces as
    /// `.failed(message:)` on the tab rather than throwing — the tab is
    /// still created so the UI has somewhere to show the error.
    public func openTab(containerID: String) async {
        let tab = Tab(containerID: containerID, state: .connecting)
        tabs.append(tab)
        selectedTabID = tab.id

        do {
            let shell = try await ShellDetector.detectShell(containerID: containerID, runtime: runtime)
            let session = try makeSession(containerID, shell)
            sessionsByTabID[tab.id] = session
            updateState(for: tab.id, to: .connected(shell: shell))
            watchersByTabID[tab.id] = Task { [weak self] in
                let code = await session.waitUntilExit()
                guard let self, !Task.isCancelled else { return }
                await self.handleSessionExited(tabID: tab.id, code: code)
            }
        } catch let error as ShellDetector.DetectionError {
            updateState(for: tab.id, to: .failed(message: Self.describe(error)))
        } catch {
            updateState(for: tab.id, to: .failed(message: String(describing: error)))
        }
    }

    /// Terminates the session (cooperative-terminate contract lives in
    /// `PTYExecSession`), cancels its watcher task, and removes the tab.
    /// Idempotent: closing an already-closed/unknown id is a no-op.
    public func closeTab(id: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        watchersByTabID[id]?.cancel()
        watchersByTabID[id] = nil

        if let session = sessionsByTabID[id] {
            await session.terminate()
        }
        sessionsByTabID[id] = nil

        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
        }
    }

    public func session(for id: UUID) -> (any TerminalSession)? {
        sessionsByTabID[id]
    }

    // MARK: - Private

    private func handleSessionExited(tabID: UUID, code: Int32?) async {
        // The watcher task is done either way once this runs; drop our
        // handle to it so `closeTab` doesn't try to cancel a finished task.
        watchersByTabID[tabID] = nil
        updateState(for: tabID, to: .exited(code: code))
    }

    private func updateState(for tabID: UUID, to newState: TabState) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].state = newState
    }

    private static func describe(_ error: ShellDetector.DetectionError) -> String {
        switch error {
        case .noShellFound(let containerID, let tried):
            return "No usable shell found in \(containerID) (tried: \(tried.joined(separator: ", ")))"
        }
    }
}
