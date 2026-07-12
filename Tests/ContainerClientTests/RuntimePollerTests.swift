import ContainerClientTestSupport
import EventBus
import Foundation
import Testing
@testable import ContainerClient

/// Buffers an `AsyncStream`'s elements behind a `next()`/`next(within:)`
/// interface so tests can await real events instead of sleeping-then-
/// asserting (swift-concurrency-pro `testing.md`). Backed by a
/// `CheckedContinuation`, resumed exactly once per waiter.
private actor EventCollector<Element: Sendable> {
    private var buffer: [Element] = []
    private var waiter: CheckedContinuation<Element?, Never>?

    func push(_ element: Element) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: element)
        } else {
            buffer.append(element)
        }
    }

    /// Cancellation-aware: a raw `withCheckedContinuation` never auto-resumes
    /// on cancellation, which would otherwise leave `next(within:)`'s losing
    /// race-child permanently suspended — and since `withTaskGroup` waits for
    /// every child to finish before returning, that one dangling waiter would
    /// hang the group (and the calling test) forever. Cancelling here instead
    /// resumes with `nil` and clears the registered waiter.
    func next() async -> Element? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    /// `nil` means the deadline elapsed with nothing published — used to
    /// prove silence (the bus never legitimately finishes in these tests, so
    /// a `nil` from `next()` itself only happens via the cancellation path
    /// above, which `flatMap` collapses to the same `nil` result anyway).
    func next(within timeout: Duration) async -> Element? {
        await withTaskGroup(of: Element??.self) { group in
            group.addTask { .some(await self.next()) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .none
            }
            defer { group.cancelAll() }
            let first = await group.next()!
            return first.flatMap { $0 }
        }
    }
}

private func makeCollector(subscribedTo bus: EventBus<RuntimeEvent>) async -> EventCollector<RuntimeEvent> {
    let collector = EventCollector<RuntimeEvent>()
    let stream = await bus.subscribe()
    Task {
        for await event in stream {
            await collector.push(event)
        }
    }
    return collector
}

@Test func pollerLifecycleEmitsExpectedEventSequence() async throws {
    let fake = FakeContainerRuntime()
    let bus = EventBus<RuntimeEvent>()
    let collector = await makeCollector(subscribedTo: bus)

    let poller = RuntimePoller(
        runtime: fake,
        events: bus,
        interval: .milliseconds(15),
        idleInterval: .milliseconds(80),
        unavailableInterval: .milliseconds(15)
    )

    let web1 = ContainerSummary(id: "web-1", status: "running", imageReference: "nginx", addresses: [])
    await fake.setContainers([web1])
    await poller.start()

    // start → snapshot
    let snapshotEvent = await collector.next()
    #expect(snapshotEvent == .snapshot([web1]))

    // add → containerAdded
    let web2 = ContainerSummary(id: "web-2", status: "running", imageReference: "nginx", addresses: [])
    await fake.setContainers([web1, web2])
    let addedEvent = await collector.next()
    #expect(addedEvent == .containerAdded(web2))

    // status change → containerStateChanged
    let web1Stopped = ContainerSummary(id: "web-1", status: "stopped", imageReference: "nginx", addresses: [])
    await fake.setContainers([web1Stopped, web2])
    let changedEvent = await collector.next()
    #expect(changedEvent == .containerStateChanged(web1Stopped, previousStatus: "running"))

    // remove → containerRemoved
    await fake.setContainers([web2])
    let removedEvent = await collector.next()
    #expect(removedEvent == .containerRemoved(id: "web-1"))

    // setError(.listContainers) → exactly one runtimeBecameUnavailable
    struct ProbeError: Error, Sendable, Equatable, LocalizedError {
        var errorDescription: String? { "synthetic apiserver outage" }
    }
    await fake.setError(ProbeError(), for: .listContainers)
    let unavailableEvent = await collector.next()
    #expect(unavailableEvent == .runtimeBecameUnavailable(message: "synthetic apiserver outage"))

    // Several more failed ticks must not repeat the event — advance past a
    // few poll intervals before clearing the error.
    let repeatedDuringOutage = await collector.next(within: .milliseconds(60))
    #expect(repeatedDuringOutage == nil)

    // clearError → runtimeBecameAvailable + snapshot
    await fake.clearError(for: .listContainers)
    let availableEvent = await collector.next()
    #expect(availableEvent == .runtimeBecameAvailable)
    let resyncSnapshot = await collector.next()
    #expect(resyncSnapshot == .snapshot([web2]))

    // stop → silence
    await poller.stop()
    let silence = await collector.next(within: .milliseconds(80))
    #expect(silence == nil)
}

@Test func pollerStartIsIdempotent() async throws {
    let fake = FakeContainerRuntime()
    await fake.setContainers([ContainerSummary(id: "a", status: "running", imageReference: nil, addresses: [])])
    let bus = EventBus<RuntimeEvent>()
    let collector = await makeCollector(subscribedTo: bus)

    let poller = RuntimePoller(runtime: fake, events: bus, interval: .milliseconds(15))
    await poller.start()
    await poller.start() // second call must be a no-op, not a second loop

    let first = await collector.next()
    #expect(first != nil)

    await poller.stop()
    await poller.stop() // idempotent, and safe even though already stopped
}
