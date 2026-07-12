/// Typed, idempotent execution steps (plan §4.5). `capsule compose plan`
/// renders these before anything runs — plan-before-run transparency is a
/// product differentiator, keep the descriptions human-readable.
public enum PlanStep: Sendable, Equatable, CustomStringConvertible {
    case ensureNetwork(name: String)
    case ensureVolume(name: String)
    case ensureImage(service: String, image: String)
    case ensureBuild(service: String, context: String)
    case ensureContainer(service: String, containerName: String)
    case start(service: String)
    case waitHealthy(service: String)

    public var description: String {
        switch self {
        case .ensureNetwork(let name):
            "ensure network \(name)"
        case .ensureVolume(let name):
            "ensure volume \(name)"
        case .ensureImage(let service, let image):
            "ensure image \(image) (for \(service))"
        case .ensureBuild(let service, let context):
            "build \(service) from \(context)"
        case .ensureContainer(let service, let containerName):
            "ensure container \(containerName) (service \(service))"
        case .start(let service):
            "start \(service)"
        case .waitHealthy(let service):
            "wait until \(service) is healthy"
        }
    }
}

public struct ExecutionPlan: Sendable, Equatable {
    public let steps: [PlanStep]

    public init(steps: [PlanStep]) {
        self.steps = steps
    }

    public var rendered: String {
        steps.enumerated()
            .map { index, step in String(format: "%2d. %@", index + 1, step.description) }
            .joined(separator: "\n")
    }
}
