import ArgumentParser
import ContainerClient
import Foundation

struct MachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "Manage persistent Apple container machines.",
        subcommands: [MachineListCommand.self, MachineInspectCommand.self, MachineCreateCommand.self, MachineStartCommand.self, MachineStopCommand.self, MachineDeleteCommand.self, MachineLogsCommand.self]
    )
}

struct MachineListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", aliases: ["ls"])
    func run() async throws {
        let values = try await makeRuntime().listMachines()
        guard !values.isEmpty else { print("No machines."); return }
        print("NAME\tSTATE\tDEFAULT\tIP\tCPUS\tMEMORY\tDISK")
        for value in values {
            let memory = ByteCountFormatter.string(fromByteCount: Int64(value.memoryBytes), countStyle: .memory)
            let disk = value.diskSizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "-"
            print("\(value.id)\t\(value.state.rawValue)\t\(value.isDefault ? "yes" : "no")\t\(value.ipAddress ?? "-")\t\(value.cpus)\t\(memory)\t\(disk)")
        }
    }
}

struct MachineInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect")
    @Argument var id: String
    func run() async throws {
        let value = try await makeRuntime().inspectMachine(id: id)
        print("Name:       \(value.id)")
        print("State:      \(value.state.rawValue)")
        print("Image:      \(value.imageReference)")
        print("Platform:   \(value.operatingSystem)/\(value.architecture)")
        print("IP:         \(value.ipAddress ?? "-")")
        print("CPUs:       \(value.cpus)")
        print("Memory:     \(ByteCountFormatter.string(fromByteCount: Int64(value.memoryBytes), countStyle: .memory))")
        print("Home mount: \(value.homeMount.rawValue)")
    }
}

struct MachineCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @Argument(help: "Machine image, for example alpine:3.22.") var image: String
    @Option(name: [.short, .long]) var name: String?
    @Option var platform: String?
    @Option var cpus: Int?
    @Option(name: .customLong("memory-bytes")) var memoryBytes: UInt64?
    @Option(name: .customLong("home-mount"), help: "Home mount mode: rw, ro, or none.") var homeMount = "rw"
    @Flag(name: .customLong("no-boot")) var noBoot = false
    @Flag(name: .customLong("set-default")) var setDefault = false
    @Flag(name: .customLong("nested-virtualization")) var nestedVirtualization = false
    func run() async throws {
        guard let resolvedHomeMount = MachineHomeMount(rawValue: homeMount) else {
            throw ValidationError("--home-mount must be one of: rw, ro, none")
        }
        let id = try await makeRuntime().createMachine(.init(
            imageReference: image,
            name: name,
            platform: platform,
            cpus: cpus,
            memoryBytes: memoryBytes,
            homeMount: resolvedHomeMount,
            bootAfterCreation: !noBoot,
            setAsDefault: setDefault,
            nestedVirtualization: nestedVirtualization
        ))
        print(id)
    }
}

struct MachineStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Boot a stopped machine.")
    @Argument var id: String
    func run() async throws { try await makeRuntime().startMachine(id: id); print(id) }
}

struct MachineStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    @Argument var id: String
    func run() async throws { try await makeRuntime().stopMachine(id: id); print(id) }
}

struct MachineDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", aliases: ["rm"])
    @Argument var id: String
    @Flag(help: "Confirm permanent deletion of the machine and its virtual disk.") var force = false
    func run() async throws {
        guard force else { throw ValidationError("Machine deletion requires --force.") }
        try await makeRuntime().deleteMachine(id: id)
        print(id)
    }
}

struct MachineLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs")
    @Argument var id: String
    @Flag var boot = false
    @Flag(name: [.short, .long]) var follow = false
    @Option(name: .short) var tail: Int?
    func run() async throws {
        let stream = try await makeRuntime().machineLogs(
            id: id,
            source: boot ? .boot : .standard,
            follow: follow,
            tail: tail
        )
        for try await line in stream { print(line.text) }
    }
}
