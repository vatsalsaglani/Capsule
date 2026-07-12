import ComposePlanner
import ContainerClient
import EventBus

public enum ComposeRuntimeError: Error, Sendable {
    case stepNotImplemented(String)
}

public enum ComposeEvent: Sendable {
    case stepStarted(PlanStep)
    case stepCompleted(PlanStep)
    case stepFailed(PlanStep, message: String)
}

/// Executes an ExecutionPlan against the runtime, emitting progress events.
/// M2 work: real step execution (pull/build/create/start via ContainerRuntime),
/// parallel independent branches, and reconcile-on-attach (plan §4.5–4.6).
public actor ComposeExecutor {
    private let runtime: any ContainerRuntime
    public let events: EventBus<ComposeEvent>

    public init(runtime: any ContainerRuntime, events: EventBus<ComposeEvent> = EventBus()) {
        self.runtime = runtime
        self.events = events
    }

    public func execute(_ plan: ExecutionPlan) async throws {
        for step in plan.steps {
            await events.publish(.stepStarted(step))
            do {
                try await execute(step)
                await events.publish(.stepCompleted(step))
            } catch {
                await events.publish(.stepFailed(step, message: String(describing: error)))
                throw error
            }
        }
    }

    private func execute(_ step: PlanStep) async throws {
        // Honest placeholder: every step fails loudly until M2 lands it.
        throw ComposeRuntimeError.stepNotImplemented(step.description)
    }
}
