import ContainerClient
import Foundation
import Observation

/// The testable state machine behind the System screen (P1B B5 — AGENTS.md
/// rule 1). On-demand like `ImagesStore` (no `RuntimeEvent` case for system
/// status/disk-usage changes): the view calls `refresh()` on appear, and this
/// store calls it again itself after a successful start/stop.
///
/// No SwiftUI import here (mirrors the other P1B stores) — `swift test`
/// exercises this headless.
@MainActor
@Observable
public final class SystemStore {
    public enum Phase: Equatable {
        case loading
        case loaded(status: SystemStatus, diskUsage: SystemDiskUsage)
        case failed(message: String)
    }

    public private(set) var phase: Phase = .loading
    /// Set when `startRuntime()`/`stopRuntime()` fails; not folded into
    /// `phase` because a start/stop failure shouldn't blank an already-loaded
    /// status card (same posture as `ContainerListStore.lastActionError`).
    public private(set) var lastActionError: String?

    private let runtime: any ContainerRuntime

    public init(runtime: any ContainerRuntime) {
        self.runtime = runtime
    }

    public func refresh() async {
        do {
            async let status = runtime.systemStatus()
            async let diskUsage = runtime.systemDiskUsage()
            phase = try await .loaded(status: status, diskUsage: diskUsage)
        } catch {
            phase = .failed(message: message(for: error))
        }
    }

    public func startRuntime() async {
        lastActionError = nil
        do {
            try await runtime.systemStart()
            await refresh()
        } catch {
            lastActionError = message(for: error)
        }
    }

    public func stopRuntime() async {
        lastActionError = nil
        do {
            try await runtime.systemStop()
            await refresh()
        } catch {
            lastActionError = message(for: error)
        }
    }

    public func dismissActionError() {
        lastActionError = nil
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
