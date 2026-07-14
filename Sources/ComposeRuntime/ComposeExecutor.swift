import ComposePlanner
import ComposeSpec
import ContainerClient
import EventBus
import Foundation
import Supervisor

/// Executes exact serialized plan layers against the runtime. Every returned
/// stream is operation-scoped; the shared bus is only a mirror for app-wide
/// observation and never mixes the caller's primary progress channel.
public actor ComposeExecutor {
    private let runtime: any ContainerRuntime
    public let events: EventBus<ComposeEvent>

    public init(runtime: any ContainerRuntime, events: EventBus<ComposeEvent> = EventBus()) {
        self.runtime = runtime
        self.events = events
    }

    public func execute(
        _ plan: ExecutionPlan,
        kind: ComposeOperationKind = .up
    ) -> AsyncThrowingStream<ComposeEvent, Error> {
        execute(plan, kind: kind, onHealthObservation: { _, _, _ in })
    }

    func execute(
        _ plan: ExecutionPlan,
        kind: ComposeOperationKind,
        onHealthObservation: @escaping @Sendable (
            _ service: String,
            _ containerID: String,
            _ observation: HealthProbeObservation
        ) async throws -> Void
    ) -> AsyncThrowingStream<ComposeEvent, Error> {
        let runtime = self.runtime
        let bus = events
        let operationID = UUID()
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ComposeEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )

        let producer = Task(name: "Compose \(kind.rawValue) \(operationID)") {
            do {
                try await Self.emitChecked(
                    .operationStarted(id: operationID, kind: kind),
                    continuation: continuation,
                    bus: bus
                )
                for layer in plan.layers {
                    try Task.checkCancellation()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for step in layer.steps {
                            group.addTask(name: step.description) {
                                try await Self.emitChecked(.stepStarted(step), continuation: continuation, bus: bus)
                                do {
                                    try await Self.execute(
                                        step,
                                        runtime: runtime,
                                        output: { message in
                                            await Self.emit(
                                                .stepOutput(step: step, message: message),
                                                continuation: continuation,
                                                bus: bus
                                            )
                                        },
                                        onHealthObservation: onHealthObservation
                                    )
                                    try await Self.emitChecked(.stepCompleted(step), continuation: continuation, bus: bus)
                                } catch {
                                    await Self.emit(
                                        .stepFailed(step, message: error.localizedDescription),
                                        continuation: continuation,
                                        bus: bus
                                    )
                                    throw error
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                }
                try await Self.emitChecked(
                    .operationCompleted(id: operationID, kind: kind),
                    continuation: continuation,
                    bus: bus
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }
        return stream
    }

    private static func emitChecked(
        _ event: ComposeEvent,
        continuation: AsyncThrowingStream<ComposeEvent, Error>.Continuation,
        bus: EventBus<ComposeEvent>
    ) async throws {
        try Task.checkCancellation()
        continuation.yield(event)
        await bus.publish(event)
    }

    private static func emit(
        _ event: ComposeEvent,
        continuation: AsyncThrowingStream<ComposeEvent, Error>.Continuation,
        bus: EventBus<ComposeEvent>
    ) async {
        continuation.yield(event)
        await bus.publish(event)
    }

    private static func execute(
        _ step: PlanStep,
        runtime: any ContainerRuntime,
        output: @escaping @Sendable (String) async -> Void,
        onHealthObservation: @escaping @Sendable (
            _ service: String,
            _ containerID: String,
            _ observation: HealthProbeObservation
        ) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        switch step {
        case .ensureNetwork(let spec):
            if !(try await runtime.listNetworks()).contains(where: { $0.name == spec.name }) {
                try await runtime.createNetwork(spec)
            }

        case .ensureVolume(let spec):
            if !(try await runtime.listVolumes()).contains(where: { $0.name == spec.name }) {
                try await runtime.createVolume(spec)
            }

        case .ensureImage(_, let image, let platform):
            if try await runtime.listImages().contains(where: { $0.reference == image }) {
                await output("image \(image) already present")
                return
            }
            let progress = try await runtime.pullImage(reference: image, platform: platform)
            for try await update in progress {
                try Task.checkCancellation()
                await output(update.message)
            }

        case .ensureBuild(_, let spec):
            let progress = try await runtime.buildImage(spec)
            for try await update in progress {
                try Task.checkCancellation()
                await output(update.message)
            }

        case .removeContainer(_, let containerID):
            try await runtime.deleteContainer(id: containerID, force: true)

        case .ensureContainer(_, let spec):
            let reference = spec.name
            let exists = try await runtime.listContainers(all: true).contains {
                $0.id == reference || $0.id == spec.name
            }
            if !exists {
                _ = try await runtime.createContainer(spec)
            }

        case .stop(_, let containerID, let timeoutSeconds):
            try await runtime.stopContainer(id: containerID, timeoutSeconds: timeoutSeconds)

        case .start(_, let containerReference):
            let containers = try await runtime.listContainers(all: true)
            if let container = containers.first(where: {
                $0.id == containerReference || $0.labels["capsule.service"] == containerReference
            }), container.runState == .running {
                return
            }
            try await runtime.startContainer(id: containerReference)

        case .waitHealthy(let service, let containerReference, let healthcheck):
            guard let plan = try healthcheckPlan(for: healthcheck, service: service) else { return }
            let runner = HealthProbeRunner(runtime: runtime)
            _ = try await runner.waitUntilHealthy(
                containerID: containerReference,
                plan: plan,
                onObservation: { observation in
                    try await onHealthObservation(service, containerReference, observation)
                    await output("health \(observation.state.rawValue) (attempt \(observation.attempt)): \(observation.output)")
                }
            )

        case .waitCompleted(let service, _):
            throw ComposeRuntimeError.successfulExitStatusUnavailable(service: service)

        case .refreshHosts(let targets):
            try await refreshHosts(targets: targets, runtime: runtime, output: output)
        }
    }

    static func refreshHosts(
        targets: [ServiceHostTarget],
        runtime: any ContainerRuntime,
        output: @escaping @Sendable (String) async -> Void
    ) async throws {
        let script = #"""
        set -eu
        umask 077
        tmp=''
        i=0
        while [ "$i" -lt 32 ]; do
            candidate="${TMPDIR:-/tmp}/capsule-hosts.$$.$i"
            if (set -C; : > "$candidate") 2>/dev/null; then
                tmp=$candidate
                break
            fi
            i=$((i + 1))
        done
        if [ -z "$tmp" ]; then
            printf '%s\n' 'capsule: unable to create hosts refresh temporary file' >&2
            exit 1
        fi
        trap 'rm -f "$tmp"' 0 1 2 3 15
        awk 'BEGIN { skip=0 } $0=="# capsule:begin" { skip=1; next } $0=="# capsule:end" { skip=0; next } !skip { print }' /etc/hosts > "$tmp"
        printf '%s\n' '# capsule:begin' "$1" '# capsule:end' >> "$tmp"
        cat "$tmp" > /etc/hosts
        """#

        for target in targets {
            try Task.checkCancellation()
            var lines: [String] = []
            for peer in target.peers {
                let detail = try await runtime.inspectContainer(id: peer.containerReference)
                guard let address = detail.networks.compactMap(\.ipAddress).first else {
                    throw ComposeRuntimeError.missingContainer(service: peer.service)
                }
                let aliases = peer.aliases.filter(isSafeHostAlias)
                guard !aliases.isEmpty else { continue }
                lines.append("\(address) \(aliases.joined(separator: " "))")
            }
            let result = try await runtime.exec(
                id: target.containerReference,
                argv: ["sh", "-c", script, "capsule-hosts", lines.joined(separator: "\n")],
                options: .containerRoot,
                timeout: .seconds(10)
            )
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RuntimeError.commandFailed(
                    command: "container exec \(target.containerReference) sh -c <hosts-refresh>",
                    exitCode: result.exitCode,
                    stderr: stderr
                )
            }
            await output("service discovery hosts refreshed for \(target.service)")
        }
    }

    private static func isSafeHostAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    static func healthcheckPlan(
        for healthcheck: Healthcheck,
        service: String
    ) throws -> HealthcheckPlan? {
        if healthcheck.disable == true { return nil }
        guard let values = healthcheck.test?.values, !values.isEmpty else {
            throw ComposeRuntimeError.invalidHealthcheck(service: service, detail: "missing test")
        }

        let argv: [String]
        switch values[0].uppercased() {
        case "NONE":
            return nil
        case "CMD":
            argv = Array(values.dropFirst())
        case "CMD-SHELL":
            argv = ["sh", "-c", values.dropFirst().joined(separator: " ")]
        default:
            argv = ["sh", "-c", values.joined(separator: " ")]
        }
        guard !argv.isEmpty else {
            throw ComposeRuntimeError.invalidHealthcheck(service: service, detail: "empty command")
        }

        func duration(_ text: String?, default fallback: Duration, field: String) throws -> Duration {
            guard let text else { return fallback }
            guard let parsed = ComposeDuration.parse(text) else {
                throw ComposeRuntimeError.invalidHealthcheck(
                    service: service,
                    detail: "invalid \(field) duration `\(text)`"
                )
            }
            return parsed
        }

        return try HealthcheckPlan(
            argv: argv,
            interval: duration(healthcheck.interval, default: .seconds(30), field: "interval"),
            timeout: duration(healthcheck.timeout, default: .seconds(30), field: "timeout"),
            retries: healthcheck.retries ?? 3,
            startPeriod: duration(healthcheck.startPeriod, default: .zero, field: "start_period")
        )
    }
}
