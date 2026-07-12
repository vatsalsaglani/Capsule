#if DEBUG
import AppCore
import ContainerClient
import ContainerClientTestSupport
import Foundation

/// **Debug-only feel-prototype harness (P1B B2, master plan §6.6).** Drives
/// one scripted container row through
/// `stopped → starting (orange) → running (green) → stopped` on a timer,
/// through the *exact* production data path every other screen uses:
/// `RuntimeSession`'s `RuntimePoller` polls a `FakeContainerRuntime`,
/// publishes `RuntimeEvent`s onto the real `EventBus`, and
/// `ContainerListStore` folds them into `phase` — so the frame-by-frame feel
/// review sees genuine poll-driven state transitions and the same
/// `ContainerRow`/`ContainerStateDot`/`ContainerInspector` the real
/// Containers screen renders, not a hand-tweaked standalone animation.
///
/// Gated out of Release builds entirely (`#if DEBUG` wraps this whole file).
/// The App target's temporary `ContainerClientTestSupport` product
/// dependency (`App/project.yml`) exists only for this file and should be
/// removed alongside it once P4 polish lands (see the P1B B2+B3 commit note).
@MainActor
final class ScriptedDemoSession {
    let session: RuntimeSession
    private let fake: FakeContainerRuntime
    private var scriptTask: Task<Void, Never>?

    init(
        pollInterval: Duration = .milliseconds(200),
        idleInterval: Duration = .milliseconds(200),
        unavailableInterval: Duration = .milliseconds(200)
    ) {
        let fake = FakeContainerRuntime()
        self.fake = fake
        self.session = RuntimeSession(
            makeRuntime: { fake },
            pollInterval: pollInterval,
            idleInterval: idleInterval,
            unavailableInterval: unavailableInterval
        )
    }

    /// Starts the real pipeline (`session.start()`) and the scripted
    /// state-change loop. Idempotent against a second call.
    func start() async {
        await session.start()
        guard scriptTask == nil else { return }
        let fake = self.fake
        scriptTask = Task {
            var isStopped = true
            while !Task.isCancelled {
                let stableStatus = isStopped ? "stopped" : "running"
                await fake.setContainers([
                    ContainerSummary(
                        id: "demo-web",
                        status: stableStatus,
                        imageReference: "nginx",
                        addresses: isStopped ? [] : ["192.168.64.10"],
                        ports: [PortMapping(hostPort: 8080, containerPort: 80)]
                    ),
                ])
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                let transitionalStatus = isStopped ? "starting" : "stopping"
                await fake.setContainers([
                    ContainerSummary(
                        id: "demo-web",
                        status: transitionalStatus,
                        imageReference: "nginx",
                        addresses: isStopped ? [] : ["192.168.64.10"],
                        ports: [PortMapping(hostPort: 8080, containerPort: 80)]
                    ),
                ])
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                isStopped.toggle()
            }
        }
    }

    func stop() async {
        scriptTask?.cancel()
        scriptTask = nil
        await session.stop()
    }
}
#endif
