import Foundation

/// AsyncStream-based broadcast bus for domain events (plan §2.1). Slow
/// subscribers drop oldest events rather than back-pressuring publishers —
/// UI consumers only ever need the recent past.
public actor EventBus<Event: Sendable> {
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    public func subscribe(bufferingNewest bufferSize: Int = 256) -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    public func publish(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        continuations[id] = nil
    }
}
