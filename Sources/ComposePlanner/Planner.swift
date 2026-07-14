import ComposeSpec
import ContainerClient
import CryptoKit
import Foundation

public enum PlannerError: Error, Sendable, Equatable {
    case unsupportedConfiguration([SupportReport.Finding])
    case unknownRequestedService(String)
    case missingHealthcheck(service: String, dependedOnBy: String)
}

public struct PlanningOptions: Codable, Sendable, Hashable {
    public var services: [String]
    public var forceRecreate: Bool
    public var noDependencies: Bool

    public init(
        services: [String] = [],
        forceRecreate: Bool = false,
        noDependencies: Bool = false
    ) {
        self.services = services
        self.forceRecreate = forceRecreate
        self.noDependencies = noDependencies
    }
}

public struct ObservedServiceState: Codable, Sendable, Hashable {
    public var service: String
    public var containerID: String
    public var containerName: String
    public var configHash: String?
    public var isRunning: Bool

    public init(
        service: String,
        containerID: String,
        containerName: String,
        configHash: String?,
        isRunning: Bool
    ) {
        self.service = service
        self.containerID = containerID
        self.containerName = containerName
        self.configHash = configHash
        self.isRunning = isRunning
    }
}

/// Pure observed input to planning. Runtime DTOs are intentionally normalized
/// at the boundary so the planner is deterministic and easy to golden-test.
public struct ObservedProjectState: Codable, Sendable, Hashable {
    public var services: [String: ObservedServiceState]
    public var volumeNames: Set<String>
    public var networkNames: Set<String>

    public init(
        services: [String: ObservedServiceState] = [:],
        volumeNames: Set<String> = [],
        networkNames: Set<String> = []
    ) {
        self.services = services
        self.volumeNames = volumeNames
        self.networkNames = networkNames
    }
}

/// Stable SHA-256 over sorted-key JSON. Swift's `Hasher` is deliberately not
/// used because its seed varies between processes.
public enum ServiceConfigHasher {
    private struct Configuration: Codable {
        let runSpec: RunSpec
        let buildSpec: ImageBuildSpec?
    }

    public static func hash(runSpec: RunSpec, buildSpec: ImageBuildSpec?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Configuration(runSpec: runSpec, buildSpec: buildSpec))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Resolved desired state + observed state → an ordered DAG of parallel
/// execution layers. The planner has no runtime access.
public struct Planner: Sendable {
    public init() {}

    public func makePlan(
        for document: ComposeDocument,
        observed: ObservedProjectState = ObservedProjectState(),
        options: PlanningOptions = PlanningOptions()
    ) throws -> ExecutionPlan {
        guard !document.support.hasFatalFindings else {
            throw PlannerError.unsupportedConfiguration(
                document.support.findings.filter { $0.severity == .fatal }
            )
        }

        let dependencies = document.file.services.mapValues { service in
            Set(service.dependsOn?.requirements.keys.map { $0 } ?? [])
        }
        _ = try DependencyGraph.startOrder(dependencies)

        let requested = Set(options.services)
        if let unknown = requested.sorted().first(where: { document.file.services[$0] == nil }) {
            throw PlannerError.unknownRequestedService(unknown)
        }

        var included = requested.isEmpty ? Set(document.file.services.keys) : requested
        if !options.noDependencies {
            included = dependencyClosure(of: included, dependencies: dependencies)
        }

        let desired = try buildDesiredServices(document: document, included: included)
        var actions = desired.mapValues { desiredService -> Action in
            guard let existing = observed.services[desiredService.name] else { return .recreate }
            if options.forceRecreate || existing.configHash != desiredService.configHash {
                return .recreate
            }
            return existing.isRunning ? .none : .start
        }

        if !options.noDependencies {
            let changed = Set(actions.compactMap { $0.value == .recreate ? $0.key : nil })
            let dependents = dependentClosure(of: changed, dependencies: dependencies)
            included.formUnion(dependents)
            included = dependencyClosure(of: included, dependencies: dependencies)

            // Newly included dependent services need their desired specs.
            let expandedDesired = try buildDesiredServices(document: document, included: included)
            for (name, service) in expandedDesired where desired[name] == nil {
                guard let existing = observed.services[name] else {
                    actions[name] = .recreate
                    continue
                }
                if existing.configHash != service.configHash {
                    actions[name] = .recreate
                } else {
                    actions[name] = existing.isRunning ? .restart : .start
                }
            }
            for name in dependents where actions[name] == Action.none {
                actions[name] = observed.services[name]?.isRunning == true ? .restart : .start
            }
            return try assemblePlan(
                document: document,
                desired: expandedDesired,
                actions: actions,
                observed: observed
            )
        }

        return try assemblePlan(
            document: document,
            desired: desired,
            actions: actions,
            observed: observed
        )
    }

    private enum Action { case none, start, recreate, restart }

    private struct DesiredService {
        let name: String
        let runSpec: RunSpec
        let buildSpec: ImageBuildSpec?
        let configHash: String
        let volumeNames: Set<String>
        let networkNames: Set<String>
        let healthcheck: Healthcheck?
        let stopTimeoutSeconds: Int?
        let requirements: [String: DependsOn.Requirement]
    }

    private struct StepNode {
        let step: PlanStep
        var prerequisites: Set<String>
    }

    private func assemblePlan(
        document: ComposeDocument,
        desired: [String: DesiredService],
        actions: [String: Action],
        observed: ObservedProjectState
    ) throws -> ExecutionPlan {
        var nodes: [String: StepNode] = [:]
        let project = document.projectName

        let requiredNetworks = Set(desired.values.flatMap(\.networkNames))
        for logicalName in requiredNetworks.sorted() {
            guard !observed.networkNames.contains(logicalName),
                  let config = networkConfig(named: logicalName, document: document)
            else { continue }
            let labels = try resourceLabels(project: project, resource: "network:\(logicalName)")
            nodes["00-network:\(logicalName)"] = StepNode(
                step: .ensureNetwork(NetworkCreateSpec(
                    name: logicalName,
                    connectivity: config.isInternal == true ? .hostOnly : .nat,
                    labels: labels
                )),
                prerequisites: []
            )
        }

        let requiredVolumes = Set(desired.values.flatMap(\.volumeNames))
        for name in requiredVolumes.sorted()
            where !observed.volumeNames.contains(name) && isManagedVolume(name, document: document) {
            let labels = try resourceLabels(project: project, resource: "volume:\(name)")
            nodes["01-volume:\(name)"] = StepNode(
                step: .ensureVolume(VolumeCreateSpec(name: name, labels: labels)),
                prerequisites: []
            )
        }

        // Runtime 1.1's custom-network plugin can wedge when network setup
        // overlaps image/container churn. Treat resource creation as a hard
        // infrastructure barrier, while still allowing resources within the
        // barrier and all subsequent image pulls/builds to run in parallel.
        let infrastructureNodeIDs = Set(nodes.keys)

        for name in desired.keys.sorted() {
            guard let service = desired[name], let action = actions[name] else { continue }
            let reference = service.runSpec.name ?? name
            let imageNodeID = "10-image:\(name)"
            let removeNodeID = "20-remove:\(name)"
            let createNodeID = "30-create:\(name)"
            let stopNodeID = "21-stop:\(name)"
            let startNodeID = "40-start:\(name)"

            if action == .recreate {
                if let build = service.buildSpec {
                    nodes[imageNodeID] = StepNode(
                        step: .ensureBuild(service: name, spec: build),
                        prerequisites: infrastructureNodeIDs
                    )
                } else {
                    nodes[imageNodeID] = StepNode(
                        step: .ensureImage(service: name, image: service.runSpec.image, platform: service.runSpec.platform),
                        prerequisites: infrastructureNodeIDs
                    )
                }

                var createPrerequisites: Set<String> = [imageNodeID]
                createPrerequisites.formUnion(service.volumeNames.compactMap { volume in
                    nodes["01-volume:\(volume)"] == nil ? nil : "01-volume:\(volume)"
                })
                createPrerequisites.formUnion(service.networkNames.compactMap { network in
                    nodes["00-network:\(network)"] == nil ? nil : "00-network:\(network)"
                })
                if let existing = observed.services[name] {
                    var removalPrerequisites: Set<String> = [imageNodeID]
                    if existing.isRunning {
                        nodes[stopNodeID] = StepNode(
                            step: .stop(
                                service: name,
                                containerID: existing.containerID,
                                timeoutSeconds: service.stopTimeoutSeconds
                            ),
                            prerequisites: infrastructureNodeIDs
                        )
                        removalPrerequisites.insert(stopNodeID)
                    }
                    nodes[removeNodeID] = StepNode(
                        step: .removeContainer(service: name, containerID: existing.containerID),
                        prerequisites: removalPrerequisites
                    )
                    createPrerequisites.insert(removeNodeID)
                }
                nodes[createNodeID] = StepNode(
                    step: .ensureContainer(service: name, spec: service.runSpec),
                    prerequisites: createPrerequisites
                )
                nodes[startNodeID] = StepNode(
                    step: .start(service: name, containerReference: reference),
                    prerequisites: [createNodeID]
                )
            } else if action == .restart, let existing = observed.services[name] {
                nodes[stopNodeID] = StepNode(
                    step: .stop(
                        service: name,
                        containerID: existing.containerID,
                        timeoutSeconds: service.stopTimeoutSeconds
                    ),
                    prerequisites: infrastructureNodeIDs
                )
                nodes[startNodeID] = StepNode(
                    step: .start(service: name, containerReference: existing.containerID),
                    prerequisites: [stopNodeID]
                )
            } else if action == .start {
                let existingReference = observed.services[name]?.containerID ?? reference
                nodes[startNodeID] = StepNode(
                    step: .start(service: name, containerReference: existingReference),
                    prerequisites: infrastructureNodeIDs
                )
            }
        }

        // Add dependency gates only to services that actually start. Healthy
        // waits are created only when a dependent explicitly requests them.
        for name in desired.keys.sorted() {
            let startNodeID = "40-start:\(name)"
            guard var startNode = nodes[startNodeID], let service = desired[name] else { continue }
            for (dependency, requirement) in service.requirements.sorted(by: { $0.key < $1.key }) {
                guard let dependencyService = desired[dependency] else { continue }
                let dependencyStart = "40-start:\(dependency)"
                switch requirement.condition {
                case .serviceStarted:
                    if nodes[dependencyStart] != nil { startNode.prerequisites.insert(dependencyStart) }
                case .serviceHealthy:
                    guard let healthcheck = dependencyService.healthcheck else {
                        throw PlannerError.missingHealthcheck(service: dependency, dependedOnBy: name)
                    }
                    let waitID = "50-healthy:\(dependency)"
                    if nodes[waitID] == nil {
                        nodes[waitID] = StepNode(
                            step: .waitHealthy(
                                service: dependency,
                                containerReference: dependencyService.runSpec.name ?? dependency,
                                healthcheck: healthcheck
                            ),
                            prerequisites: nodes[dependencyStart] == nil ? [] : [dependencyStart]
                        )
                    }
                    if nodes[waitID] != nil { startNode.prerequisites.insert(waitID) }
                case .serviceCompletedSuccessfully:
                    let waitID = "51-completed:\(dependency)"
                    if nodes[waitID] == nil {
                        nodes[waitID] = StepNode(
                            step: .waitCompleted(
                                service: dependency,
                                containerReference: dependencyService.runSpec.name ?? dependency
                            ),
                            prerequisites: nodes[dependencyStart] == nil ? [] : [dependencyStart]
                        )
                    }
                    startNode.prerequisites.insert(waitID)
                }
            }
            nodes[startNodeID] = startNode
        }

        // Health commands may resolve peer service names. Inject the managed
        // hosts block after all peer containers exist and each health target
        // is running, but before any health gate executes. The ordinary final
        // refresh remains below so every subsequent up/reconcile can repair
        // changed IPs even when no health wait is present.
        let healthyServices = nodes.values.compactMap { node -> String? in
            guard case .waitHealthy(let service, _, _) = node.step else { return nil }
            return service
        }
        if !healthyServices.isEmpty {
            let serviceDependencies = desired.mapValues { Set($0.requirements.keys) }
            let peerNamesByTarget = Dictionary(uniqueKeysWithValues: healthyServices.map { service in
                var peers = dependencyClosure(of: Set([service]), dependencies: serviceDependencies)
                peers.remove(service)
                return (service, peers)
            })
            let healthTargets = makeHostTargets(
                desired: desired,
                targetNames: Set(healthyServices),
                peerNamesByTarget: peerNamesByTarget
            )
            var prerequisites = Set(nodes.keys.filter { $0.hasPrefix("30-create:") })
            prerequisites.formUnion(healthyServices.compactMap { service in
                nodes["40-start:\(service)"] == nil ? nil : "40-start:\(service)"
            })
            let preHealthID = "45-refresh-hosts-before-health"
            nodes[preHealthID] = StepNode(
                step: .refreshHosts(targets: healthTargets),
                prerequisites: prerequisites
            )
            for id in nodes.keys where id.hasPrefix("50-healthy:") {
                nodes[id]?.prerequisites.insert(preHealthID)
            }
        }

        if desired.count > 1 {
            let targets = makeHostTargets(desired: desired, targetNames: Set(desired.keys))
            let gates = Set(nodes.keys.filter {
                $0.hasPrefix("40-start:") || $0.hasPrefix("50-healthy:") || $0.hasPrefix("51-completed:")
            })
            nodes["60-refresh-hosts"] = StepNode(
                step: .refreshHosts(targets: targets),
                prerequisites: gates
            )
        }

        return ExecutionPlan(layers: makeLayers(nodes))
    }

    private func makeLayers(_ nodes: [String: StepNode]) -> [PlanLayer] {
        var remaining = nodes
        var completed = Set<String>()
        var layers: [PlanLayer] = []
        while !remaining.isEmpty {
            let ready = remaining.keys.filter { id in
                remaining[id]?.prerequisites.isSubset(of: completed) == true
            }.sorted()
            // Service dependency cycles are validated before step construction;
            // this guard prevents an internal planner bug from spinning forever.
            guard !ready.isEmpty else { break }
            layers.append(PlanLayer(steps: ready.compactMap { remaining[$0]?.step }))
            for id in ready {
                remaining.removeValue(forKey: id)
                completed.insert(id)
            }
        }
        return layers
    }

    private func buildDesiredServices(
        document: ComposeDocument,
        included: Set<String>
    ) throws -> [String: DesiredService] {
        var result: [String: DesiredService] = [:]
        for name in included.sorted() {
            guard let service = document.file.services[name] else { continue }
            let normalized = try normalize(service: service, name: name, document: document)
            result[name] = normalized
        }
        return result
    }

    private func normalize(
        service: ComposeService,
        name: String,
        document: ComposeDocument
    ) throws -> DesiredService {
        let project = document.projectName
        let containerName = "\(project)-\(name)-1"
        let buildTag = service.image ?? "capsule-\(project)-\(name):latest"
        var runSpec = RunSpec(image: buildTag)
        runSpec.name = containerName
        runSpec.command = service.command?.values ?? []
        if let entrypoint = service.entrypoint?.values, let first = entrypoint.first {
            runSpec.entrypoint = first
            runSpec.command = Array(entrypoint.dropFirst()) + runSpec.command
        }
        runSpec.environment = (service.environment?.entries ?? [:]).reduce(into: [:]) { output, entry in
            if let value = entry.value ?? document.environment[entry.key] {
                output[entry.key] = value
            }
        }
        runSpec.workingDirectory = service.workingDir
        runSpec.user = service.user
        runSpec.ports = (service.ports ?? []).map {
            ContainerClient.PortMapping(
                hostAddress: $0.hostIP,
                hostPort: $0.published ?? 0,
                containerPort: $0.target,
                proto: $0.proto.lowercased() == "udp" ? .udp : .tcp
            )
        }

        var volumeNames = Set<String>()
        runSpec.mounts = (service.volumes ?? []).enumerated().map { index, mount in
            switch mount.kind {
            case .bind:
                let source = resolvePath(mount.source ?? ".", relativeTo: document.workingDirectory)
                return .bind(source: source, target: mount.target, readOnly: mount.readOnly)
            case .volume:
                let logical = mount.source ?? "\(name)_anonymous_\(index + 1)"
                let runtimeName = volumeName(logical, document: document)
                volumeNames.insert(runtimeName)
                return .volume(name: runtimeName, target: mount.target, readOnly: mount.readOnly)
            case .tmpfs:
                return .tmpfs(target: mount.target)
            }
        }
        for target in service.tmpfs?.values ?? [] {
            runSpec.mounts.append(.tmpfs(target: target))
        }

        let requestedNetworks = service.networks?.values ?? ["default"]
        let networkNames = Set(requestedNetworks.map { networkName($0, document: document) })
        runSpec.networks = networkNames.sorted()
        runSpec.platform = service.platform
        runSpec.useInit = service.initProcess ?? false
        runSpec.readOnly = service.readOnly ?? false
        runSpec.shmSize = service.shmSize?.value
        let baseLabels = (service.labels?.entries ?? [:]).reduce(into: [String: String]()) { output, entry in
            if let value = entry.value ?? document.environment[entry.key] {
                output[entry.key] = value
            }
        }.merging([
            "capsule.project": project,
            "capsule.service": name,
            "capsule.index": "1",
        ]) { _, capsule in capsule }
        runSpec.labels = baseLabels

        let buildSpec: ImageBuildSpec? = service.build.map { build in
            let context = URL(fileURLWithPath: resolvePath(build.context, relativeTo: document.workingDirectory), isDirectory: true)
            let dockerfile = build.dockerfile.map { value in
                URL(fileURLWithPath: resolvePath(value, relativeTo: context.path))
            }
            let arguments = (build.args?.entries ?? [:]).reduce(into: [String: String]()) { output, entry in
                if let value = entry.value ?? document.environment[entry.key] {
                    output[entry.key] = value
                }
            }
            return ImageBuildSpec(
                contextDirectory: context,
                dockerfile: dockerfile,
                tag: buildTag,
                arguments: arguments,
                target: build.target,
                platform: service.platform,
                labels: baseLabels
            )
        }

        let configHash = try ServiceConfigHasher.hash(runSpec: runSpec, buildSpec: buildSpec)
        runSpec.labels["capsule.config-hash"] = configHash
        var resolvedBuild = buildSpec
        resolvedBuild?.labels["capsule.config-hash"] = configHash
        return DesiredService(
            name: name,
            runSpec: runSpec,
            buildSpec: resolvedBuild,
            configHash: configHash,
            volumeNames: volumeNames,
            networkNames: networkNames,
            healthcheck: service.healthcheck,
            stopTimeoutSeconds: Self.stopTimeoutSeconds(service.stopGracePeriod),
            requirements: service.dependsOn?.requirements ?? [:]
        )
    }

    private func makeHostTargets(
        desired: [String: DesiredService],
        targetNames: Set<String>,
        peerNamesByTarget: [String: Set<String>]? = nil
    ) -> [ServiceHostTarget] {
        targetNames.sorted().compactMap { targetName in
            guard let target = desired[targetName] else { return nil }
            let peerNames = peerNamesByTarget?[targetName] ?? Set(desired.keys)
            let peers = peerNames.sorted().compactMap { peerName -> ServiceHostPeer? in
                guard peerName != targetName, let peer = desired[peerName] else { return nil }
                return ServiceHostPeer(
                    service: peerName,
                    containerReference: peer.runSpec.name ?? peerName,
                    aliases: [peerName]
                )
            }
            return ServiceHostTarget(
                service: targetName,
                containerReference: target.runSpec.name ?? targetName,
                peers: peers
            )
        }
    }

    private static func stopTimeoutSeconds(_ text: String?) -> Int? {
        guard let text, let duration = ComposeDuration.parse(text) else { return nil }
        let components = duration.components
        let seconds = Int(clamping: components.seconds)
        return max(0, seconds + (components.attoseconds > 0 ? 1 : 0))
    }

    private func dependencyClosure(
        of initial: Set<String>,
        dependencies: [String: Set<String>]
    ) -> Set<String> {
        var result = initial
        var frontier = Array(initial)
        while let service = frontier.popLast() {
            for dependency in dependencies[service] ?? [] where result.insert(dependency).inserted {
                frontier.append(dependency)
            }
        }
        return result
    }

    private func dependentClosure(
        of initial: Set<String>,
        dependencies: [String: Set<String>]
    ) -> Set<String> {
        var result = Set<String>()
        var frontier = Array(initial)
        while let service = frontier.popLast() {
            for dependent in dependencies.keys.sorted()
                where dependencies[dependent]?.contains(service) == true
                    && result.insert(dependent).inserted {
                frontier.append(dependent)
            }
        }
        return result
    }

    private func volumeName(_ logical: String, document: ComposeDocument) -> String {
        guard let config = document.file.namedVolumes[logical] else {
            return "\(document.projectName)_\(logical)"
        }
        if config.external == true { return config.name ?? logical }
        return config.name ?? "\(document.projectName)_\(logical)"
    }

    private func networkName(_ logical: String, document: ComposeDocument) -> String {
        guard let config = document.file.namedNetworks[logical] else {
            return "\(document.projectName)_\(logical)"
        }
        if config.external == true { return config.name ?? logical }
        return config.name ?? "\(document.projectName)_\(logical)"
    }

    private func isManagedVolume(_ runtimeName: String, document: ComposeDocument) -> Bool {
        for (logical, config) in document.file.namedVolumes
            where volumeName(logical, document: document) == runtimeName {
            return config.external != true
        }
        return true
    }

    private func networkConfig(named runtimeName: String, document: ComposeDocument) -> TopLevelNetwork? {
        if runtimeName == "\(document.projectName)_default" {
            return document.file.namedNetworks["default"] ?? TopLevelNetwork()
        }
        for (logical, config) in document.file.namedNetworks
            where networkName(logical, document: document) == runtimeName {
            return config.external == true ? nil : config
        }
        return TopLevelNetwork()
    }

    private func resourceLabels(project: String, resource: String) throws -> [String: String] {
        [
            "capsule.project": project,
            // Apple container 1.1 misparses an empty `key=` label. Resource
            // identity is deterministic and nonempty, while retaining the
            // four-label ownership contract shared with containers.
            "capsule.service": resource,
            "capsule.index": "0",
            "capsule.config-hash": try ServiceConfigHasher.hash(resource),
        ]
    }

    private func resolvePath(_ path: String, relativeTo directory: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
    }
}
