public enum DependencyGraphError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownService(name: String, dependedOnBy: String)
    case dependencyCycle(path: [String])

    public var description: String {
        switch self {
        case .unknownService(let name, let dependedOnBy):
            "service \(dependedOnBy) depends on unknown service \(name)"
        case .dependencyCycle(let path):
            "dependency cycle: \(path.joined(separator: " → "))"
        }
    }
}

public enum DependencyGraph {
    /// Topological start order for `dependencies` (service → the services it
    /// depends on). Deterministic: alphabetical tie-break. Cycles are fatal
    /// with the cycle printed (plan §4.5).
    public static func startOrder(_ dependencies: [String: Set<String>]) throws -> [String] {
        for (service, deps) in dependencies.sorted(by: { $0.key < $1.key }) {
            for dep in deps.sorted() where dependencies[dep] == nil {
                throw DependencyGraphError.unknownService(name: dep, dependedOnBy: service)
            }
        }

        var remaining = dependencies
        var order: [String] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { $0.value.allSatisfy { !remaining.keys.contains($0) } }
                .keys.sorted()
            guard !ready.isEmpty else {
                throw DependencyGraphError.dependencyCycle(path: findCycle(in: remaining))
            }
            for service in ready {
                order.append(service)
                remaining.removeValue(forKey: service)
            }
        }
        return order
    }

    private static func findCycle(in dependencies: [String: Set<String>]) -> [String] {
        var visited = Set<String>()
        var path: [String] = []
        var onPath = Set<String>()

        func dfs(_ node: String) -> [String]? {
            if onPath.contains(node) {
                let start = path.firstIndex(of: node) ?? path.startIndex
                return Array(path[start...]) + [node]
            }
            if visited.contains(node) { return nil }
            visited.insert(node)
            path.append(node)
            onPath.insert(node)
            defer {
                path.removeLast()
                onPath.remove(node)
            }
            for next in (dependencies[node] ?? []).sorted() {
                if let cycle = dfs(next) { return cycle }
            }
            return nil
        }

        for node in dependencies.keys.sorted() {
            if let cycle = dfs(node) { return cycle }
        }
        return []
    }
}
