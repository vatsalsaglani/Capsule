import ComposePlanner
import Testing

@Test func dependencyGraphProducesDeterministicParallelStartLayers() throws {
    let layers = try DependencyGraph.startLayers([
        "worker": ["database", "cache"],
        "web": ["database", "cache"],
        "database": [],
        "cache": [],
    ])

    #expect(layers == [
        ["cache", "database"],
        ["web", "worker"],
    ])
    #expect(try DependencyGraph.startOrder([
        "worker": ["database", "cache"],
        "web": ["database", "cache"],
        "database": [],
        "cache": [],
    ]) == layers.flatMap { $0 })
}
