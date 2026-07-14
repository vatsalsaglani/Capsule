import ContainerClient
import Foundation

public actor BuildCenter {
    private let runtime: any ContainerRuntime
    private let historyStore: BuildHistoryStore
    private var active: [BuildID: Task<Void, Never>] = [:]
    private var preparing: Set<BuildID> = []
    private var builderMutationInProgress = false

    public init(
        runtime: any ContainerRuntime,
        historyStore: BuildHistoryStore = BuildHistoryStore()
    ) {
        self.runtime = runtime
        self.historyStore = historyStore
    }

    public func start(_ request: BuildRequest) async throws -> BuildExecution {
        guard !builderMutationInProgress else { throw BuildCenterError.builderBusy }
        let resolved = try BuildRequestResolver.resolve(request)
        let id = BuildID()
        preparing.insert(id)
        let summary = BuildRequestSummary(
            contextPath: resolved.spec.contextDirectory.path,
            dockerfilePath: resolved.spec.dockerfile?.path ?? "Dockerfile",
            tags: resolved.tags,
            argumentKeys: resolved.argumentKeys,
            target: resolved.spec.target,
            platform: resolved.spec.platform,
            cachePolicy: resolved.spec.cachePolicy,
            baseImagePolicy: resolved.spec.baseImagePolicy
        )
        let record = BuildRecord(id: id, request: summary)
        do {
            try await historyStore.upsert(record)
        } catch {
            preparing.remove(id)
            throw error
        }

        let (events, continuation) = AsyncStream.makeStream(
            of: BuildEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(
                id: id,
                resolved: resolved,
                initialRecord: record,
                continuation: continuation
            )
        }
        active[id] = task
        preparing.remove(id)
        return BuildExecution(id: id, events: events)
    }

    public func cancel(id: BuildID) async {
        guard let task = active[id] else { return }
        task.cancel()
        await task.value
    }

    public func history() async throws -> [BuildRecord] {
        try await historyStore.records()
    }

    public func clearHistory() async throws {
        try await historyStore.clear()
    }

    public func builderStatus() async throws -> BuilderStatus {
        try await runtime.builderStatus()
    }

    public func startBuilder(_ configuration: BuilderConfiguration = .init()) async throws {
        try beginBuilderMutation()
        defer { builderMutationInProgress = false }
        try await runtime.startBuilder(configuration)
    }

    public func stopBuilder() async throws {
        try beginBuilderMutation()
        defer { builderMutationInProgress = false }
        try await runtime.stopBuilder()
    }

    public func resetBuilder(_ configuration: BuilderConfiguration = .init()) async throws {
        try beginBuilderMutation()
        defer { builderMutationInProgress = false }
        try await runtime.deleteBuilder(force: true)
        try await runtime.startBuilder(configuration)
    }

    private func beginBuilderMutation() throws {
        guard active.isEmpty, preparing.isEmpty else { throw BuildCenterError.activeBuilds }
        guard !builderMutationInProgress else { throw BuildCenterError.builderBusy }
        builderMutationInProgress = true
    }

    private func run(
        id: BuildID,
        resolved: ResolvedBuildRequest,
        initialRecord: BuildRecord,
        continuation: AsyncStream<BuildEvent>.Continuation
    ) async {
        var record = initialRecord
        var output: [BuildProgress] = []
        continuation.yield(.started(record))
        do {
            let progress = try await runtime.buildImage(resolved.spec)
            for try await line in progress {
                try Task.checkCancellation()
                let safeLine = redacted(line, values: Array(resolved.spec.arguments.values))
                output.append(safeLine)
                if output.count > BuildHistoryStore.maximumOutputLines {
                    output.removeFirst(output.count - BuildHistoryStore.maximumOutputLines)
                }
                continuation.yield(.progress(safeLine))
            }

            for tag in resolved.tags.dropFirst() {
                try Task.checkCancellation()
                continuation.yield(.tagging(tag))
                try await runtime.tagImage(source: resolved.tags[0], target: tag)
            }
            record.state = .succeeded
        } catch is CancellationError {
            record.state = .cancelled
        } catch {
            record.state = .failed
            record.failureMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        record.finishedAt = Date()
        record.output = output
        try? await historyStore.upsert(record)
        continuation.yield(.finished(record))
        continuation.finish()
        active[id] = nil
    }

    /// Build tools may echo resolved `--build-arg` values. Keep those
    /// values out of both the live Capsule surface and durable history.
    private func redacted(_ progress: BuildProgress, values: [String]) -> BuildProgress {
        let message = values
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(progress.message) { result, value in
                result.replacingOccurrences(of: value, with: "<redacted>")
            }
        return BuildProgress(message: message, receivedAt: progress.receivedAt)
    }
}
