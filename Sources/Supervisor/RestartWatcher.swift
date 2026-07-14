import ContainerClient
import Foundation

public struct SupervisedService: Sendable, Codable, Equatable {
    public var service: String
    public var containerID: String
    public var policy: RestartPolicy

    public init(service: String, containerID: String, policy: RestartPolicy) {
        self.service = service
        self.containerID = containerID
        self.policy = policy
    }
}

public struct ServiceSupervisionState: Sendable, Codable, Equatable {
    public var attempts: Int
    public var stoppedByUser: Bool
    public var restartScheduled: Bool

    public init(attempts: Int = 0, stoppedByUser: Bool = false, restartScheduled: Bool = false) {
        self.attempts = attempts
        self.stoppedByUser = stoppedByUser
        self.restartScheduled = restartScheduled
    }
}

public struct SupervisorSnapshot: Sendable, Codable, Equatable {
    public var services: [String: ServiceSupervisionState]

    public init(services: [String: ServiceSupervisionState] = [:]) {
        self.services = services
    }
}

public enum RestartDecision: Sendable, Equatable {
    case none
    case schedule(service: String, containerID: String, delay: Duration)
    /// CLI 1.1.x does not expose a stopped container's exit status. Exact
    /// `on-failure` behavior must remain paused rather than guessed.
    case exitStatusUnavailable(service: String, containerID: String)
}

public enum SupervisorEvent: Sendable, Equatable {
    case restartScheduled(service: String, containerID: String, delay: Duration)
    case restarted(service: String, containerID: String)
    case restartFailed(service: String, containerID: String, message: String)
    case warning(service: String, message: String)
}

/// Serializable restart decision state. Runtime calls and sleeps happen in
/// `RestartWatcher`, outside this actor, so its isolation is never held across
/// slow subprocess work.
public actor RestartCoordinator {
    private var servicesByContainer: [String: SupervisedService]
    private var snapshotValue: SupervisorSnapshot

    public init(services: [SupervisedService], snapshot: SupervisorSnapshot = .init()) {
        servicesByContainer = Dictionary(
            services.map { ($0.containerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        snapshotValue = snapshot
        for service in services where snapshotValue.services[service.service] == nil {
            snapshotValue.services[service.service] = .init()
        }
    }

    public func snapshot() -> SupervisorSnapshot { snapshotValue }

    public func setStoppedByUser(_ stopped: Bool, service: String) {
        var state = snapshotValue.services[service] ?? .init()
        state.stoppedByUser = stopped
        if stopped { state.restartScheduled = false }
        snapshotValue.services[service] = state
    }

    public func containerStopped(containerID: String, exitCode: Int32?) -> RestartDecision {
        guard let descriptor = servicesByContainer[containerID] else { return .none }
        var state = snapshotValue.services[descriptor.service] ?? .init()
        guard !state.restartScheduled else { return .none }
        guard !state.stoppedByUser else { return .none }

        if case .onFailure = descriptor.policy, exitCode == nil {
            return .exitStatusUnavailable(service: descriptor.service, containerID: containerID)
        }

        guard descriptor.policy.shouldRestart(
            exitCode: exitCode ?? 0,
            wasStoppedByUser: state.stoppedByUser,
            attemptsSoFar: state.attempts
        ) else { return .none }

        let delay = RestartPolicy.backoffDelay(attempt: state.attempts)
        state.attempts += 1
        state.restartScheduled = true
        snapshotValue.services[descriptor.service] = state
        return .schedule(service: descriptor.service, containerID: containerID, delay: delay)
    }

    public func restartFinished(service: String, succeeded: Bool) {
        var state = snapshotValue.services[service] ?? .init()
        state.restartScheduled = false
        if succeeded {
            state.stoppedByUser = false
        }
        snapshotValue.services[service] = state
    }
}

/// Consumes Poller/XPC events and applies restart decisions. The CLI Poller
/// currently supplies no exit status, so `on-failure` emits an honest warning;
/// a future XPC event can pass the real status without reshaping coordinator
/// state.
public struct RestartWatcher: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias EventSink = @Sendable (SupervisorEvent) async -> Void

    private let runtime: any ContainerRuntime
    private let coordinator: RestartCoordinator
    private let sleep: Sleeper

    public init(
        runtime: any ContainerRuntime,
        coordinator: RestartCoordinator,
        sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) }
    ) {
        self.runtime = runtime
        self.coordinator = coordinator
        self.sleep = sleep
    }

    public func run(
        events: AsyncStream<RuntimeEvent>,
        onEvent: @escaping EventSink = { _ in }
    ) async {
        await withDiscardingTaskGroup { group in
            for await event in events {
                guard !Task.isCancelled else { break }
                guard case .containerStateChanged(let summary, _) = event,
                      summary.runState == .stopped
                else { continue }

                let decision = await coordinator.containerStopped(
                    containerID: summary.id,
                    exitCode: nil
                )
                switch decision {
                case .none:
                    continue
                case .exitStatusUnavailable(let service, let containerID):
                    await onEvent(.warning(
                        service: service,
                        message: "Cannot apply restart: on-failure because container 1.1.x does not expose \(containerID)'s exit status."
                    ))
                case .schedule(let service, let containerID, let delay):
                    await onEvent(.restartScheduled(
                        service: service,
                        containerID: containerID,
                        delay: delay
                    ))
                    group.addTask {
                        do {
                            try await sleep(delay)
                            try Task.checkCancellation()
                            try await runtime.startContainer(id: containerID)
                            await coordinator.restartFinished(service: service, succeeded: true)
                            await onEvent(.restarted(service: service, containerID: containerID))
                        } catch is CancellationError {
                            await coordinator.restartFinished(service: service, succeeded: false)
                        } catch {
                            await coordinator.restartFinished(service: service, succeeded: false)
                            await onEvent(.restartFailed(
                                service: service,
                                containerID: containerID,
                                message: error.localizedDescription
                            ))
                        }
                    }
                }
            }
        }
    }
}
