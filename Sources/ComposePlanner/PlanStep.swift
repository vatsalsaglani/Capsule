import ComposeSpec
import ContainerClient
import Foundation

public struct ServiceHostPeer: Codable, Sendable, Hashable {
    public let service: String
    public let containerReference: String
    public let aliases: [String]

    public init(service: String, containerReference: String, aliases: [String]) {
        self.service = service
        self.containerReference = containerReference
        self.aliases = aliases
    }
}

public struct ServiceHostTarget: Codable, Sendable, Hashable {
    public let service: String
    public let containerReference: String
    public let peers: [ServiceHostPeer]

    public init(service: String, containerReference: String, peers: [ServiceHostPeer]) {
        self.service = service
        self.containerReference = containerReference
        self.peers = peers
    }
}

/// One executable, idempotent operation. Inputs are deliberately embedded so
/// an `ExecutionPlan` can be serialized, reviewed, stored, and executed later
/// without re-reading compose files or ambient environment state.
public enum PlanStep: Codable, Sendable, Hashable, CustomStringConvertible {
    case ensureNetwork(NetworkCreateSpec)
    case ensureVolume(VolumeCreateSpec)
    case ensureImage(service: String, image: String, platform: String?)
    case ensureBuild(service: String, spec: ImageBuildSpec)
    case removeContainer(service: String, containerID: String)
    case ensureContainer(service: String, spec: RunSpec)
    case stop(service: String, containerID: String, timeoutSeconds: Int?)
    case start(service: String, containerReference: String)
    case waitHealthy(service: String, containerReference: String, healthcheck: Healthcheck)
    case waitCompleted(service: String, containerReference: String)
    /// S1 shipping mechanism: inspect peer IPs and idempotently refresh the
    /// Capsule-managed `/etc/hosts` block in each target container.
    case refreshHosts(targets: [ServiceHostTarget])

    public var description: String {
        switch self {
        case .ensureNetwork(let spec):
            "ensure network \(spec.name)"
        case .ensureVolume(let spec):
            "ensure volume \(spec.name)"
        case .ensureImage(let service, let image, _):
            "ensure image \(image) (for \(service))"
        case .ensureBuild(let service, let spec):
            "build \(service) from \(spec.contextDirectory.path)"
        case .removeContainer(let service, let containerID):
            "remove \(containerID) (changed service \(service))"
        case .ensureContainer(let service, let spec):
            "ensure container \(spec.name ?? service) (service \(service))"
        case .stop(let service, let containerID, _):
            "stop \(containerID) (dependent service \(service))"
        case .start(let service, let containerReference):
            "start \(containerReference) (service \(service))"
        case .waitHealthy(let service, _, _):
            "wait until \(service) is healthy"
        case .waitCompleted(let service, _):
            "wait until \(service) completes successfully"
        case .refreshHosts(let targets):
            "refresh service discovery hosts for \(targets.map(\.service).joined(separator: ", "))"
        }
    }
}

/// Steps inside one layer may execute concurrently. Layers are strictly
/// ordered, making the parallelism explicit and serializable.
public struct PlanLayer: Codable, Sendable, Hashable {
    public let steps: [PlanStep]

    public init(steps: [PlanStep]) {
        self.steps = steps
    }
}

public struct ExecutionPlan: Codable, Sendable, Hashable {
    public let layers: [PlanLayer]

    public init(layers: [PlanLayer]) {
        self.layers = layers.filter { !$0.steps.isEmpty }
    }

    /// Compatibility initializer for callers that intentionally need a
    /// sequential plan.
    public init(steps: [PlanStep]) {
        self.init(layers: steps.map { PlanLayer(steps: [$0]) })
    }

    public var steps: [PlanStep] {
        layers.flatMap(\.steps)
    }

    public var rendered: String {
        var ordinal = 0
        return layers.enumerated().flatMap { layerIndex, layer in
            layer.steps.map { step in
                ordinal += 1
                return String(
                    format: "%2d. [layer %d] %@",
                    ordinal,
                    layerIndex + 1,
                    step.description
                )
            }
        }.joined(separator: "\n")
    }
}
