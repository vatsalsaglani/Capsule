import BuildManager
import ContainerClient
import Foundation
import Observation

@MainActor
@Observable
public final class BuildsStore {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public enum BuilderAction: Equatable {
        case idle
        case working
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var builderStatus: BuilderStatus = .absent
    public private(set) var history: [BuildRecord] = []
    public private(set) var activeBuildID: BuildID?
    public private(set) var activeRecord: BuildRecord?
    public private(set) var liveOutput: [BuildProgress] = []
    public private(set) var tagging: String?
    public private(set) var builderAction: BuilderAction = .idle
    public private(set) var lastError: String?

    private let center: BuildCenter
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(center: BuildCenter) {
        self.center = center
    }

    deinit { observationTask?.cancel() }

    public var isBuilding: Bool { activeBuildID != nil }

    public func refresh() async {
        phase = history.isEmpty ? .loading : .loaded
        do {
            async let status = center.builderStatus()
            async let records = center.history()
            builderStatus = try await status
            history = try await records
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
        }
    }

    public func start(_ request: BuildRequest) async {
        guard !isBuilding else { return }
        lastError = nil
        liveOutput = []
        tagging = nil
        do {
            let execution = try await center.start(request)
            activeBuildID = execution.id
            observationTask?.cancel()
            observationTask = Task { [weak self] in
                guard let self else { return }
                for await event in execution.events {
                    guard !Task.isCancelled else { return }
                    self.consume(event)
                }
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        } catch {
            lastError = message(for: error)
        }
    }

    public func start(_ input: BuildFormInput) async {
        lastError = nil
        do {
            await start(try input.request())
        } catch {
            lastError = message(for: error)
        }
    }

    public func cancelActiveBuild() async {
        guard let id = activeBuildID else { return }
        await center.cancel(id: id)
    }

    public func startBuilder(_ configuration: BuilderConfiguration = .init()) async {
        await performBuilderAction { try await self.center.startBuilder(configuration) }
    }

    public func stopBuilder() async {
        await performBuilderAction { try await self.center.stopBuilder() }
    }

    public func resetBuilder(_ configuration: BuilderConfiguration = .init()) async {
        await performBuilderAction { try await self.center.resetBuilder(configuration) }
    }

    public func clearHistory() async {
        do {
            try await center.clearHistory()
            history = []
        } catch {
            lastError = message(for: error)
        }
    }

    public func dismissError() {
        lastError = nil
        if case .failed = builderAction { builderAction = .idle }
    }

    private func consume(_ event: BuildEvent) {
        switch event {
        case .started(let record):
            activeRecord = record
        case .progress(let progress):
            liveOutput.append(progress)
            if liveOutput.count > BuildHistoryStore.maximumOutputLines {
                liveOutput.removeFirst(liveOutput.count - BuildHistoryStore.maximumOutputLines)
            }
        case .tagging(let tag):
            tagging = tag
        case .finished(let record):
            activeRecord = record
            activeBuildID = nil
            tagging = nil
            if record.state == .failed { lastError = record.failureMessage }
        }
    }

    private func performBuilderAction(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async {
        builderAction = .working
        do {
            try await operation()
            builderStatus = try await center.builderStatus()
            builderAction = .idle
        } catch {
            let value = message(for: error)
            builderAction = .failed(value)
            lastError = value
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
