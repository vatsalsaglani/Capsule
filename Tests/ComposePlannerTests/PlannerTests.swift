import Testing
import ComposeSpec
@testable import ComposePlanner

@Test func planRespectsDependencyOrderAndResourcesFirst() throws {
    let document = try ComposeParser().parse(yaml: """
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
        volumes:
          - pgdata:/var/lib/postgresql/data
        healthcheck:
          test: ["CMD", "pg_isready"]
    volumes:
      pgdata: {}
    """)
    let plan = try Planner().makePlan(for: document)

    #expect(plan.steps.first == .ensureNetwork(name: "stack_default"))
    #expect(plan.steps.contains(.ensureVolume(name: "stack_pgdata")))

    let startOrder = plan.steps.compactMap { step -> String? in
        if case .start(let service) = step { return service }
        return nil
    }
    #expect(startOrder == ["db", "api", "web"])

    let dbStart = try #require(plan.steps.firstIndex(of: .start(service: "db")))
    let dbHealthy = try #require(plan.steps.firstIndex(of: .waitHealthy(service: "db")))
    let apiStart = try #require(plan.steps.firstIndex(of: .start(service: "api")))
    #expect(dbStart < dbHealthy)
    #expect(dbHealthy < apiStart)
}

@Test func dependencyCycleIsFatalWithThePathPrinted() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      a:
        image: alpine
        depends_on: [b]
      b:
        image: alpine
        depends_on: [a]
    """)
    #expect(throws: DependencyGraphError.self) {
        try Planner().makePlan(for: document)
    }
    do {
        _ = try Planner().makePlan(for: document)
    } catch let error as DependencyGraphError {
        guard case .dependencyCycle(let path) = error else {
            Issue.record("expected a cycle, got \(error)")
            return
        }
        #expect(path.contains("a"))
        #expect(path.contains("b"))
    }
}

@Test func unknownDependencyIsFatal() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      web:
        image: nginx
        depends_on: [ghost]
    """)
    #expect(throws: DependencyGraphError.unknownService(name: "ghost", dependedOnBy: "web")) {
        try Planner().makePlan(for: document)
    }
}

@Test func deterministicOrderForIndependentServices() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      zeta: { image: alpine }
      alpha: { image: alpine }
      mid: { image: alpine }
    """)
    let plan = try Planner().makePlan(for: document)
    let startOrder = plan.steps.compactMap { step -> String? in
        if case .start(let service) = step { return service }
        return nil
    }
    #expect(startOrder == ["alpha", "mid", "zeta"])
}
