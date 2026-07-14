import ArgumentParser
import BuildManager
import ContainerClient
import Foundation

struct DirectBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an image from a local directory with durable Capsule history."
    )

    @Argument(help: "Build context directory.") var context: String
    @Option(name: [.short, .long], help: "Image tag; repeat for additional aliases.") var tag: [String] = []
    @Option(name: .customLong("file"), help: "Dockerfile path; auto-detected when omitted.") var dockerfile: String?
    @Option(name: .customLong("build-arg"), help: "Build argument as KEY=VALUE; repeatable.") var buildArguments: [String] = []
    @Option(help: "Target build stage.") var target: String?
    @Option(help: "Target platform, for example linux/arm64.") var platform: String?
    @Flag(name: .customLong("no-cache"), help: "Disable build cache.") var noCache = false
    @Flag(help: "Always pull base images.") var pull = false

    func run() async throws {
        let runtime = try makeRuntime()
        let center = BuildCenter(runtime: runtime)
        let execution = try await center.start(BuildRequest(
            contextDirectory: URL(filePath: context),
            dockerfile: dockerfile.map { URL(filePath: $0) },
            tags: tag,
            arguments: try BuildArgumentInputParser.parse(buildArguments),
            target: target,
            platform: platform,
            cachePolicy: noCache ? .noCache : .useCache,
            baseImagePolicy: pull ? .pull : .useLocal
        ))

        var result: BuildRecord?
        await withTaskCancellationHandler {
            for await event in execution.events {
                switch event {
                case .started(let record):
                    print("Building \(record.request.tags.joined(separator: ", "))")
                case .progress(let progress):
                    print(progress.message)
                case .tagging(let tag):
                    print("Tagging \(tag)")
                case .finished(let record):
                    result = record
                }
            }
        } onCancel: {
            Task { await center.cancel(id: execution.id) }
        }

        guard let result else { throw ExitCode.failure }
        switch result.state {
        case .succeeded:
            print("Built \(result.request.tags.joined(separator: ", "))")
        case .cancelled:
            throw CleanExit.message("Build cancelled.")
        case .failed:
            throw ValidationError(result.failureMessage ?? "Build failed.")
        case .running:
            throw ExitCode.failure
        }
    }
}

struct BuilderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builder",
        abstract: "Inspect and manage Capsule's image builder.",
        subcommands: [BuilderStatusCommand.self, BuilderStartCommand.self, BuilderStopCommand.self, BuilderResetCommand.self]
    )
}

struct BuilderStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    func run() async throws {
        let status = try await makeRuntime().builderStatus()
        print("State:  \(status.state.rawValue)")
        if let id = status.containerID { print("ID:     \(id)") }
        if let image = status.imageReference { print("Image:  \(image)") }
        if let cpus = status.cpus { print("CPUs:   \(cpus)") }
        if let memory = status.memoryBytes { print("Memory: \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))") }
    }
}

struct BuilderStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")
    @Option(help: "Builder CPU count.") var cpus: Int?
    @Option(name: .customLong("memory-bytes"), help: "Builder memory in bytes.") var memoryBytes: UInt64?
    func run() async throws {
        try await makeRuntime().startBuilder(.init(cpus: cpus, memoryBytes: memoryBytes))
        print("Builder started.")
    }
}

struct BuilderStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    func run() async throws { try await makeRuntime().stopBuilder(); print("Builder stopped.") }
}

struct BuilderResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Delete and recreate the builder."
    )
    @Option var cpus: Int?
    @Option(name: .customLong("memory-bytes")) var memoryBytes: UInt64?
    func run() async throws {
        let center = BuildCenter(runtime: try makeRuntime())
        try await center.resetBuilder(.init(cpus: cpus, memoryBytes: memoryBytes))
        print("Builder reset.")
    }
}
