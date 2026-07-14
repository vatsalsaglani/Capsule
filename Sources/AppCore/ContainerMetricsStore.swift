import ContainerClient
import Foundation
import Observation

/// Visibility-driven aggregate metrics for resource collections. The view
/// owns the structured `.task` that awaits `observe(ids:)`, so leaving the
/// screen cancels runtime polling immediately instead of leaving a detached
/// observer behind.
@MainActor
@Observable
public final class ContainerMetricsStore {
    public private(set) var latestByID: [String: StatsSample] = [:]
    public private(set) var errorMessage: String?
    public private(set) var isCollecting = false

    private let runtime: any ContainerRuntime

    public init(runtime: any ContainerRuntime) {
        self.runtime = runtime
    }

    public func observe(ids: [String]) async {
        let ids = Array(Set(ids)).sorted()
        latestByID = latestByID.filter { ids.contains($0.key) }
        errorMessage = nil
        guard !ids.isEmpty else {
            isCollecting = false
            return
        }

        isCollecting = true
        defer { isCollecting = false }
        do {
            let requested = Set(ids)
            let stream = try await runtime.stats(ids: ids)
            for try await tick in stream {
                try Task.checkCancellation()
                latestByID = Dictionary(uniqueKeysWithValues: tick
                    .filter { requested.contains($0.id) }
                    .map { ($0.id, $0) })
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    public func sample(for id: String) -> StatsSample? {
        latestByID[id]
    }

    public var totalMemoryUsageBytes: UInt64 {
        latestByID.values.reduce(0) { total, sample in
            let (sum, overflow) = total.addingReportingOverflow(sample.memoryUsageBytes)
            return overflow ? .max : sum
        }
    }
}
