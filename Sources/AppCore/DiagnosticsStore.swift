import Diagnostics
import Foundation
import Observation

/// Main-actor adapter shared by onboarding and System. Runtime check policy
/// and incident privacy remain in CapsuleKit's Diagnostics target; this type
/// only owns observable presentation state and stale-refresh suppression.
@MainActor
@Observable
public final class DiagnosticsStore {
    public private(set) var snapshot: DiagnosticsSnapshot = .idle
    public private(set) var history: DiagnosticHistoryPage = .init(
        records: [],
        totalCount: 0,
        omittedCount: 0
    )
    public private(set) var historyError: String?
    public private(set) var isRefreshing = false

    public let incidentHistory: any IncidentHistoryServing

    private let provider: any RuntimeDiagnosticsProviding
    private var generation = UUID()

    public init(
        provider: any RuntimeDiagnosticsProviding = RuntimeDiagnostics(),
        incidentHistory: any IncidentHistoryServing = LocalIncidentHistory()
    ) {
        self.provider = provider
        self.incidentHistory = incidentHistory
    }

    public func refresh(_ request: DiagnosticsRequest = .standard) async {
        let current = UUID()
        generation = current
        isRefreshing = true
        defer {
            if generation == current { isRefreshing = false }
        }

        for await next in provider.snapshots(for: request) {
            guard generation == current, !Task.isCancelled else { return }
            snapshot = next
            if next.completedAt != nil {
                await recordBlockingDiagnosticFailure(from: next)
            }
        }
    }

    public func loadHistory(limit: Int = 50) async {
        do {
            history = try await incidentHistory.history(limit: limit)
            historyError = nil
        } catch {
            historyError = Self.describe(error)
        }
    }

    public func makeExport(limit: Int = 200) async -> DiagnosticExport? {
        do {
            let export = try await incidentHistory.makeExport(limit: limit)
            historyError = nil
            return export
        } catch {
            historyError = Self.describe(error)
            return nil
        }
    }

    public func clearHistory() async {
        do {
            try await incidentHistory.removeAll()
            history = .init(records: [], totalCount: 0, omittedCount: 0)
            historyError = nil
        } catch {
            historyError = Self.describe(error)
        }
    }

    public func record(_ incident: DiagnosticIncidentInput) async {
        do {
            _ = try await incidentHistory.record(incident)
            await loadHistory()
        } catch {
            historyError = Self.describe(error)
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func recordBlockingDiagnosticFailure(from snapshot: DiagnosticsSnapshot) async {
        let kind: DiagnosticIncidentKind?
        if snapshot.checks.contains(where: { $0.id == .binary && $0.status == .failed }) {
            kind = .binaryMissing
        } else if let version = snapshot.checks.first(where: { $0.id == .version && $0.status == .failed }) {
            kind = version.summary.localizedCaseInsensitiveContains("unsupported")
                ? .unsupportedRuntime
                : .runtimeUnavailable
        } else {
            kind = nil
        }
        guard let kind else { return }
        do {
            _ = try await incidentHistory.record(.init(
                surface: .app,
                component: .runtime,
                operation: kind == .binaryMissing ? .runtimeDiscovery : .runtimeVersion,
                kind: kind,
                severity: .error
            ))
        } catch {
            // Recording is best-effort and must never replace the doctor's
            // real result with a secondary persistence error.
        }
    }
}
