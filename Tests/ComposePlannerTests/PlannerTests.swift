import ComposeSpec
import ContainerClient
import Foundation
import Testing
@testable import ComposePlanner

private func layerIndex(
    in plan: ExecutionPlan,
    matching predicate: (PlanStep) -> Bool
) -> Int? {
    plan.layers.firstIndex { $0.steps.contains(where: predicate) }
}

private func serviceName(starting step: PlanStep) -> String? {
    guard case .start(let service, _) = step else { return nil }
    return service
}

private func runSpec(for service: String, in plan: ExecutionPlan) -> RunSpec? {
    plan.steps.compactMap { step -> RunSpec? in
        guard case .ensureContainer(let candidate, let spec) = step, candidate == service else { return nil }
        return spec
    }.first
}

private let dependencyFixture = """
name: stack
services:
  web:
    image: nginx
    depends_on: [api]
  api:
    image: api:latest
    depends_on:
      db:
        condition: service_healthy
  db:
    image: postgres:16
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: [CMD, pg_isready]
  metrics:
    image: prom/prometheus
volumes:
  pgdata: {}
"""

@Test func planCarriesExecutableInputsAndParallelLayers() throws {
    let document = try ComposeParser().parse(yaml: dependencyFixture)
    let plan = try Planner().makePlan(for: document)

    let network = try #require(plan.steps.compactMap { step -> NetworkCreateSpec? in
        guard case .ensureNetwork(let spec) = step else { return nil }
        return spec
    }.first)
    #expect(network.name == "stack_default")
    #expect(network.labels["capsule.project"] == "stack")
    #expect(network.labels["capsule.service"] == "network:stack_default")

    let volume = try #require(plan.steps.compactMap { step -> VolumeCreateSpec? in
        guard case .ensureVolume(let spec) = step else { return nil }
        return spec
    }.first)
    #expect(volume.name == "stack_pgdata")
    #expect(volume.labels["capsule.service"] == "volume:stack_pgdata")

    let db = try #require(runSpec(for: "db", in: plan))
    #expect(db.name == "stack-db-1")
    #expect(db.mounts == [.volume(name: "stack_pgdata", target: "/var/lib/postgresql/data", readOnly: false)])
    #expect(db.labels["capsule.config-hash"]?.count == 64)

    let dbStart = try #require(layerIndex(in: plan) {
        if case .start("db", _) = $0 { true } else { false }
    })
    let dbHealthy = try #require(layerIndex(in: plan) {
        if case .waitHealthy("db", _, _) = $0 { true } else { false }
    })
    let apiStart = try #require(layerIndex(in: plan) {
        if case .start("api", _) = $0 { true } else { false }
    })
    #expect(dbStart < dbHealthy)
    #expect(dbHealthy < apiStart)

    let discoveryLayer = try #require(layerIndex(in: plan) {
        if case .refreshHosts(let targets) = $0 { targets.contains { $0.service == "api" } } else { false }
    })
    #expect(discoveryLayer > apiStart)
    let discoveryTargets = try #require(plan.steps.compactMap { step -> [ServiceHostTarget]? in
        guard case .refreshHosts(let targets) = step,
              targets.contains(where: { $0.service == "api" })
        else { return nil }
        return targets
    }.first)
    let apiTarget = try #require(discoveryTargets.first { $0.service == "api" })
    #expect(apiTarget.containerReference == "stack-api-1")
    #expect(apiTarget.peers.contains {
        $0.service == "db" && $0.containerReference == "stack-db-1" && $0.aliases == ["db"]
    })

    let imageLayer = try #require(layerIndex(in: plan) {
        if case .ensureImage = $0 { true } else { false }
    })
    let imageServices = Set(plan.layers[imageLayer].steps.compactMap { step -> String? in
        guard case .ensureImage(let service, _, _) = step else { return nil }
        return service
    })
    #expect(imageServices == ["api", "db", "metrics", "web"])
    let infrastructureLayer = try #require(layerIndex(in: plan) {
        if case .ensureNetwork = $0 { true } else { false }
    })
    #expect(infrastructureLayer < imageLayer)
    #expect(plan.layers[infrastructureLayer].steps.contains { if case .ensureVolume = $0 { true } else { false } })
}

@Test func infrastructureBarrierGoldenPlanKeepsPullsParallelAfterResources() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      web:
        image: nginx:latest
        networks: [frontend]
      db:
        image: postgres:16
        volumes: [data:/var/lib/postgresql/data]
        networks: [frontend]
    volumes:
      data: {}
    networks:
      frontend: {}
    """)

    let plan = try Planner().makePlan(for: document)
    #expect(plan.rendered == """
     1. [layer 1] ensure network demo_frontend
     2. [layer 1] ensure volume demo_data
     3. [layer 2] ensure image postgres:16 (for db)
     4. [layer 2] ensure image nginx:latest (for web)
     5. [layer 3] ensure container demo-db-1 (service db)
     6. [layer 3] ensure container demo-web-1 (service web)
     7. [layer 4] start demo-db-1 (service db)
     8. [layer 4] start demo-web-1 (service web)
     9. [layer 5] refresh service discovery hosts for db, web
    """)
}

@Test func unchangedObservedServicesProduceNoContainerWork() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app: { image: alpine }
    """)
    let initial = try Planner().makePlan(for: document)
    let spec = try #require(runSpec(for: "app", in: initial))
    let observed = ObservedProjectState(
        services: ["app": .init(
            service: "app",
            containerID: "abc",
            containerName: "demo-app-1",
            configHash: spec.labels["capsule.config-hash"],
            isRunning: true
        )],
        networkNames: ["demo_default"]
    )
    let plan = try Planner().makePlan(for: document, observed: observed)
    #expect(plan.steps.isEmpty)
}

@Test func changedServiceRecreatesAndRestartsDependentsInOrder() throws {
    let document = try ComposeParser().parse(yaml: dependencyFixture)
    let desired = try Planner().makePlan(for: document)
    var observedServices: [String: ObservedServiceState] = [:]
    for name in ["db", "api", "web", "metrics"] {
        let spec = try #require(runSpec(for: name, in: desired))
        observedServices[name] = .init(
            service: name,
            containerID: "id-\(name)",
            containerName: "stack-\(name)-1",
            configHash: name == "db" ? "stale" : spec.labels["capsule.config-hash"],
            isRunning: true
        )
    }
    let plan = try Planner().makePlan(
        for: document,
        observed: .init(
            services: observedServices,
            volumeNames: ["stack_pgdata"],
            networkNames: ["stack_default"]
        )
    )

    #expect(plan.steps.contains { if case .removeContainer("db", "id-db") = $0 { true } else { false } })
    #expect(plan.steps.contains { if case .stop("api", "id-api", _) = $0 { true } else { false } })
    #expect(plan.steps.contains { if case .stop("web", "id-web", _) = $0 { true } else { false } })
    #expect(!plan.steps.contains { if case .stop("metrics", _, _) = $0 { true } else { false } })

    let dbStart = try #require(layerIndex(in: plan) { serviceName(starting: $0) == "db" })
    let apiStart = try #require(layerIndex(in: plan) { serviceName(starting: $0) == "api" })
    let webStart = try #require(layerIndex(in: plan) { serviceName(starting: $0) == "web" })
    #expect(dbStart < apiStart)
    #expect(apiStart < webStart)
}

@Test func noDependenciesLimitsASelectedService() throws {
    let document = try ComposeParser().parse(yaml: dependencyFixture)
    let plan = try Planner().makePlan(
        for: document,
        options: PlanningOptions(services: ["api"], noDependencies: true)
    )
    let touchedServices = Set(plan.steps.compactMap { step -> String? in
        switch step {
        case .ensureImage(let service, _, _), .ensureBuild(let service, _),
             .ensureContainer(let service, _), .start(let service, _): service
        default: nil
        }
    })
    #expect(touchedServices == ["api"])
}

@Test func forceRecreateOverridesMatchingHashes() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app: { image: alpine }
    """)
    let initial = try Planner().makePlan(for: document)
    let spec = try #require(runSpec(for: "app", in: initial))
    let observed = ObservedProjectState(
        services: ["app": .init(
            service: "app", containerID: "old", containerName: "demo-app-1",
            configHash: spec.labels["capsule.config-hash"], isRunning: true
        )]
    )
    let plan = try Planner().makePlan(
        for: document,
        observed: observed,
        options: PlanningOptions(forceRecreate: true)
    )
    #expect(plan.steps.contains { if case .removeContainer("app", "old") = $0 { true } else { false } })
    #expect(runSpec(for: "app", in: plan) != nil)
}

@Test func onlyHealthyDependencyWaitsForHealth() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      db:
        image: postgres
        healthcheck: { test: [CMD, pg_isready] }
      fast:
        image: alpine
        depends_on: [db]
      careful:
        image: alpine
        depends_on:
          db: { condition: service_healthy }
    """)
    let plan = try Planner().makePlan(for: document)
    let fast = try #require(layerIndex(in: plan) { serviceName(starting: $0) == "fast" })
    let healthy = try #require(layerIndex(in: plan) {
        if case .waitHealthy("db", _, _) = $0 { true } else { false }
    })
    let careful = try #require(layerIndex(in: plan) { serviceName(starting: $0) == "careful" })
    #expect(fast < healthy)
    #expect(healthy < careful)

    let preHealthCandidates = plan.steps.compactMap { step -> [ServiceHostTarget]? in
        guard case .refreshHosts(let targets) = step,
              targets.count == 1,
              targets.first?.service == "db"
        else { return nil }
        return targets
    }
    let preHealthTargets = try #require(preHealthCandidates.first)
    // `fast` and `careful` depend on db, so neither is guaranteed started
    // before db's health gate and neither may be inspected here.
    #expect(preHealthTargets[0].peers.isEmpty)
}

@Test func configHashIsCanonicalAndSemantic() throws {
    let first = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        image: alpine
        environment: { B: two, A: one }
        labels: { z: last, a: first }
    """)
    let reordered = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        labels: { a: first, z: last }
        environment: { A: one, B: two }
        image: alpine
    """)
    let changed = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        image: alpine
        environment: { A: changed, B: two }
        labels: { a: first, z: last }
    """)
    let firstHash = try #require(runSpec(for: "app", in: Planner().makePlan(for: first))?.labels["capsule.config-hash"])
    let reorderedHash = try #require(runSpec(for: "app", in: Planner().makePlan(for: reordered))?.labels["capsule.config-hash"])
    let changedHash = try #require(runSpec(for: "app", in: Planner().makePlan(for: changed))?.labels["capsule.config-hash"])
    #expect(firstHash == reorderedHash)
    #expect(firstHash != changedHash)
}

@Test func buildAndImageUseTheSameExplicitTag() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        image: registry.example/app:v2
        build: { context: . }
    """)
    let plan = try Planner().makePlan(for: document)
    let run = try #require(runSpec(for: "app", in: plan))
    let build = try #require(plan.steps.compactMap { step -> ImageBuildSpec? in
        guard case .ensureBuild("app", let spec) = step else { return nil }
        return spec
    }.first)
    #expect(run.image == "registry.example/app:v2")
    #expect(build.tag == run.image)
}

@Test func stopGracePeriodRoundsUpAndOrdersStopBeforeRemoval() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        image: alpine
        stop_grace_period: 1500ms
    """)
    let desired = try Planner().makePlan(for: document)
    let spec = try #require(runSpec(for: "app", in: desired))
    let observed = ObservedProjectState(services: [
        "app": .init(
            service: "app", containerID: "old", containerName: "demo-app-1",
            configHash: "stale", isRunning: true
        ),
    ])
    let plan = try Planner().makePlan(for: document, observed: observed)
    let stop = try #require(layerIndex(in: plan) {
        if case .stop("app", "old", 2) = $0 { true } else { false }
    })
    let remove = try #require(layerIndex(in: plan) {
        if case .removeContainer("app", "old") = $0 { true } else { false }
    })
    #expect(stop < remove)
    #expect(spec.image == "alpine")
}

@Test func externalResourcesAreAttachedButNeverCreatedOrLabeled() throws {
    let document = try ComposeParser().parse(yaml: """
    name: demo
    services:
      app:
        image: alpine
        volumes: [dbdata:/data]
        networks: [shared]
    volumes:
      dbdata: { external: true, name: company-db }
    networks:
      shared: { external: true, name: company-net }
    """)
    let plan = try Planner().makePlan(for: document)
    let spec = try #require(runSpec(for: "app", in: plan))
    #expect(spec.mounts == [.volume(name: "company-db", target: "/data", readOnly: false)])
    #expect(spec.networks == ["company-net"])
    #expect(!plan.steps.contains { if case .ensureVolume = $0 { true } else { false } })
    #expect(!plan.steps.contains { if case .ensureNetwork = $0 { true } else { false } })
}

@Test func planAndResolvedDocumentRoundTripCodable() throws {
    let document = try ComposeParser().parse(yaml: dependencyFixture)
    let plan = try Planner().makePlan(for: document)
    #expect(try JSONDecoder().decode(ExecutionPlan.self, from: JSONEncoder().encode(plan)) == plan)
    #expect(try JSONDecoder().decode(ComposeDocument.self, from: JSONEncoder().encode(document)) == document)
}

@Test func dependencyCycleIsFatalWithThePathPrinted() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      a: { image: alpine, depends_on: [b] }
      b: { image: alpine, depends_on: [a] }
    """)
    #expect(throws: DependencyGraphError.self) { try Planner().makePlan(for: document) }
}

@Test func unknownDependencyIsFatal() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      web: { image: nginx, depends_on: [ghost] }
    """)
    #expect(throws: PlannerError.self) {
        try Planner().makePlan(for: document)
    }
}

@Test func requestedUnknownServiceIsFatal() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app: { image: alpine }
    """)
    #expect(throws: PlannerError.unknownRequestedService("ghost")) {
        try Planner().makePlan(for: document, options: PlanningOptions(services: ["ghost"]))
    }
}
