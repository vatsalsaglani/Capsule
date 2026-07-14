import ArgumentParser
import ContainerClient
import Foundation

func makeRuntime() throws -> any ContainerRuntime {
    RuntimeGateway(base: try CLIProcessClient())
}

enum ResourceCommandRendering {
    static func owner(_ owner: ResourceOwner) -> String {
        switch owner {
        case .capsule(let project): project.map { "capsule:\($0)" } ?? "capsule"
        case .external: "external"
        case .system: "system"
        }
    }

    static func labels(_ values: [String]) throws -> [String: String] {
        try Dictionary(values.map { value in
            guard let separator = value.firstIndex(of: "=") else {
                throw ValidationError("label must be KEY=VALUE: \(value)")
            }
            return (String(value[..<separator]), String(value[value.index(after: separator)...]))
        }, uniquingKeysWith: { _, last in last })
    }
}

struct VolumesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volumes",
        abstract: "Manage persistent volumes.",
        subcommands: [VolumeListCommand.self, VolumeCreateCommand.self, VolumeInspectCommand.self, VolumeDeleteCommand.self, VolumePruneCommand.self]
    )
}

struct VolumeListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List volumes and their consumers.", aliases: ["ls"])
    func run() async throws {
        let inventory = try await RuntimeResourceInventory.load(from: makeRuntime())
        guard !inventory.volumes.isEmpty else { print("No volumes."); return }
        print("NAME\tSIZE\tOWNER\tUSED BY")
        for record in inventory.volumes {
            let size = record.summary.sizeInBytes.map(String.init) ?? "-"
            let users = record.usedBy.map(\.id).joined(separator: ",")
            print("\(record.summary.name)\t\(size)\t\(ResourceCommandRendering.owner(record.owner))\t\(users.isEmpty ? "-" : users)")
        }
    }
}

struct VolumeCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a volume.")
    @Argument var name: String
    @Option(name: .customLong("capacity"), help: "Capacity in bytes.") var capacityBytes: UInt64?
    @Option(name: .customLong("label"), help: "Label as KEY=VALUE; repeatable.") var labels: [String] = []
    func run() async throws {
        try await makeRuntime().createVolume(VolumeCreateSpec(
            name: name, capacityBytes: capacityBytes, labels: try ResourceCommandRendering.labels(labels)
        ))
        print(name)
    }
}

struct VolumeInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Show a volume and reverse references.")
    @Argument var name: String
    func run() async throws {
        let inventory = try await RuntimeResourceInventory.load(from: makeRuntime())
        guard let record = inventory.volume(named: name) else { throw ValidationError("volume not found: \(name)") }
        print("name: \(record.summary.name)")
        print("driver: \(record.summary.driver ?? "-")")
        print("format: \(record.summary.format ?? "-")")
        print("size: \(record.summary.sizeInBytes.map(String.init) ?? "-")")
        print("owner: \(ResourceCommandRendering.owner(record.owner))")
        print("used by: \(record.usedBy.map(\.id).joined(separator: ", ").nilIfEmpty ?? "-")")
    }
}

struct VolumeDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a volume.", aliases: ["rm"])
    @Argument var name: String
    @Flag(name: .customLong("force"), help: "Confirm permanent data deletion.") var force = false
    func run() async throws {
        guard force else { throw ValidationError("volume deletion is irreversible; pass --force") }
        let runtime = try makeRuntime()
        let inventory = try await RuntimeResourceInventory.load(from: runtime)
        if let volume = inventory.volume(named: name), !volume.usedBy.isEmpty {
            throw ValidationError("volume \(name) is used by \(volume.usedBy.map(\.id).joined(separator: ", "))")
        }
        try await runtime.deleteVolume(name: name)
        print(name)
    }
}

struct VolumePruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Delete unused volumes.")
    @Flag(name: .customLong("force"), help: "Confirm permanent deletion of unused volume data.") var force = false
    func run() async throws {
        guard force else { throw ValidationError("volume prune is irreversible; pass --force") }
        let report = try await makeRuntime().pruneVolumes()
        if report.removedNames.isEmpty { print("No unused volumes removed.") }
        else { report.removedNames.forEach { print($0) } }
        report.notices.forEach { print($0) }
    }
}

struct NetworksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "networks",
        abstract: "Manage container networks.",
        subcommands: [NetworkListCommand.self, NetworkCreateCommand.self, NetworkInspectCommand.self, NetworkDeleteCommand.self, NetworkPruneCommand.self]
    )
}

struct NetworkListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List networks and attachments.", aliases: ["ls"])
    func run() async throws {
        let inventory = try await RuntimeResourceInventory.load(from: makeRuntime())
        guard !inventory.networks.isEmpty else { print("No networks."); return }
        print("NAME\tMODE\tSUBNET\tOWNER\tCONTAINERS")
        for record in inventory.networks {
            let containers = record.connectedContainers.map(\.id).joined(separator: ",")
            print("\(record.summary.name)\t\(record.summary.mode ?? "-")\t\(record.summary.status?.ipv4Subnet ?? "-")\t\(ResourceCommandRendering.owner(record.owner))\t\(containers.isEmpty ? "-" : containers)")
        }
    }
}

struct NetworkCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a NAT or host-only network.")
    @Argument var name: String
    @Flag(name: .customLong("internal"), help: "Create a host-only network.") var isInternal = false
    @Option(name: .customLong("subnet")) var ipv4Subnet: String?
    @Option(name: .customLong("subnet-v6")) var ipv6Subnet: String?
    @Option(name: .customLong("label"), help: "Label as KEY=VALUE; repeatable.") var labels: [String] = []
    func run() async throws {
        try await makeRuntime().createNetwork(NetworkCreateSpec(
            name: name,
            connectivity: isInternal ? .hostOnly : .nat,
            ipv4Subnet: ipv4Subnet,
            ipv6Subnet: ipv6Subnet,
            labels: try ResourceCommandRendering.labels(labels)
        ))
        print(name)
    }
}

struct NetworkInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Show network configuration and attachments.")
    @Argument var name: String
    func run() async throws {
        let inventory = try await RuntimeResourceInventory.load(from: makeRuntime())
        guard let record = inventory.network(named: name) else { throw ValidationError("network not found: \(name)") }
        print("name: \(record.summary.name)")
        print("mode: \(record.summary.mode ?? "-")")
        print("IPv4 subnet: \(record.summary.status?.ipv4Subnet ?? "-")")
        print("IPv4 gateway: \(record.summary.status?.ipv4Gateway ?? "-")")
        print("IPv6 subnet: \(record.summary.status?.ipv6Subnet ?? "-")")
        print("owner: \(ResourceCommandRendering.owner(record.owner))")
        print("containers: \(record.connectedContainers.map(\.id).joined(separator: ", ").nilIfEmpty ?? "-")")
    }
}

struct NetworkDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a network.", aliases: ["rm"])
    @Argument var name: String
    func run() async throws { try await makeRuntime().deleteNetwork(name: name); print(name) }
}

struct NetworkPruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Delete unused networks.")
    func run() async throws {
        let report = try await makeRuntime().pruneNetworks()
        if report.removedNames.isEmpty { print("No unused networks removed.") }
        else { report.removedNames.forEach { print($0) } }
        report.notices.forEach { print($0) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
