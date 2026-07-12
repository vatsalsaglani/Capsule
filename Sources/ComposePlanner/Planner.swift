import ComposeSpec

public enum PlannerError: Error, Sendable {
    case unsupportedConfiguration([SupportReport.Finding])
}

/// Desired state → ExecutionPlan. v0 emits a sequential plan; diffing against
/// observed state (config-hash reconciliation) and parallel branches arrive in
/// M2 (plan §4.5).
public struct Planner: Sendable {
    public init() {}

    public func makePlan(for document: ComposeDocument) throws -> ExecutionPlan {
        guard !document.support.hasFatalFindings else {
            throw PlannerError.unsupportedConfiguration(
                document.support.findings.filter { $0.severity == .fatal }
            )
        }

        let project = document.projectName
        var steps: [PlanStep] = []

        // Project resources first. Naming: <project>_default network,
        // <project>_<volume> volumes, <project>-<service>-<n> containers
        // (plan §4.3); all get capsule.* labels at execution time.
        steps.append(.ensureNetwork(name: "\(project)_default"))
        for name in document.file.namedVolumes.keys.sorted() {
            steps.append(.ensureVolume(name: "\(project)_\(name)"))
        }

        let dependencies = document.file.services.mapValues { service in
            Set(service.dependsOn?.requirements.keys.map { $0 } ?? [])
        }
        for serviceName in try DependencyGraph.startOrder(dependencies) {
            guard let service = document.file.services[serviceName] else { continue }
            if let image = service.image {
                steps.append(.ensureImage(service: serviceName, image: image))
            } else if let build = service.build {
                steps.append(.ensureBuild(service: serviceName, context: build.context))
            }
            steps.append(.ensureContainer(
                service: serviceName,
                containerName: "\(project)-\(serviceName)-1"
            ))
            steps.append(.start(service: serviceName))
            // Sequential v0: a healthcheck always gates the next service.
            // M2 relaxes this to gate only dependents with service_healthy.
            if service.healthcheck != nil {
                steps.append(.waitHealthy(service: serviceName))
            }
        }
        return ExecutionPlan(steps: steps)
    }
}
