import ArgumentParser
import ComposeRuntime
import ComposeSpec
import ContainerClient
import Foundation
import ProjectStore

struct ComposeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Compose-style multi-container projects on Apple `container`.",
        subcommands: [
            ComposeConfigCommand.self, ComposePlanCommand.self, ComposeUpCommand.self,
            ComposeDownCommand.self, ComposePsCommand.self, ComposeLogsCommand.self,
            ComposeReconcileCommand.self,
            ComposeStartCommand.self, ComposeStopCommand.self, ComposeRestartCommand.self,
            ComposeBuildCommand.self, ComposePullCommand.self, ComposeExecCommand.self,
        ]
    )
}

struct ComposeFileOptions: ParsableArguments {
    @Option(name: [.customShort("f"), .customLong("file")], help: "Compose file.")
    var file: String?

    @Option(name: [.customShort("p"), .customLong("project-name")], help: "Override the project name.")
    var projectName: String?

    @Option(name: .customLong("env-file"), help: "Interpolation environment file.")
    var environmentFile: String?

    func loadSource() throws -> ComposeSource {
        let fileURL = try resolveFileURL()
        let envURL = environmentFile.map { URL(fileURLWithPath: $0) }
        if let envURL, !FileManager.default.fileExists(atPath: envURL.path) {
            throw ValidationError("environment file not found: \(envURL.path)")
        }
        return try ComposeSourceLoader.load(
            fileURL: fileURL,
            projectName: projectName,
            environmentFileURL: envURL
        )
    }

    private func resolveFileURL() throws -> URL {
        if let file {
            let url = URL(fileURLWithPath: file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("compose file not found: \(file)")
            }
            return url
        }
        for candidate in ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
            where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw ValidationError("no compose file found in the current directory; pass -f <path>")
    }
}

/// `logs` reserves `-f` for follow, matching Compose conventions; its file
/// option is therefore long-form only to avoid an ambiguous parser surface.
struct ComposeLogsFileOptions: ParsableArguments {
    @Option(name: .customLong("file"), help: "Compose file.") var file: String?
    @Option(name: [.customShort("p"), .customLong("project-name")]) var projectName: String?
    @Option(name: .customLong("env-file")) var environmentFile: String?

    func loadSource() throws -> ComposeSource {
        let url: URL
        if let file {
            url = URL(fileURLWithPath: file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("compose file not found: \(file)")
            }
        } else if let candidate = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }) {
            url = URL(fileURLWithPath: candidate)
        } else {
            throw ValidationError("no compose file found in the current directory; pass --file <path>")
        }
        let envURL = environmentFile.map { URL(fileURLWithPath: $0) }
        return try ComposeSourceLoader.load(fileURL: url, projectName: projectName, environmentFileURL: envURL)
    }
}

private func openProject(_ options: ComposeFileOptions) async throws -> ComposeProject {
    let runtime = RuntimeGateway(base: try CLIProcessClient())
    return try await ComposeEngine(runtime: runtime).open(options.loadSource())
}

private func openProject(_ options: ComposeLogsFileOptions) async throws -> ComposeProject {
    let runtime = RuntimeGateway(base: try CLIProcessClient())
    return try await ComposeEngine(runtime: runtime).open(options.loadSource())
}

private struct ComposeCLIContext: Sendable {
    let runtime: RuntimeGateway
    let store: ProjectStore
    let stateCoordinator: ProjectStateCoordinator
    let engine: ComposeEngine

    init() throws {
        let runtime = RuntimeGateway(base: try CLIProcessClient())
        let store = ProjectStore()
        let stateCoordinator = ProjectStateCoordinator(store: store)
        self.runtime = runtime
        self.store = store
        self.stateCoordinator = stateCoordinator
        self.engine = ComposeEngine(
            runtime: runtime,
            store: store,
            stateCoordinator: stateCoordinator
        )
    }

    func open(_ options: ComposeFileOptions) async throws -> ComposeProject {
        try await engine.open(options.loadSource())
    }
}

private actor ComposeForegroundReporter {
    private var noticeIDs: Set<String> = []
    private var healthByService: [String: String] = [:]

    func consume(_ snapshot: ComposeSupervisionSnapshot) {
        let notices = snapshot.notices + snapshot.projects.flatMap(\.notices)
        for notice in notices where noticeIDs.insert(notice.id).inserted {
            let service = notice.service.map { " [\($0)]" } ?? ""
            print("⚠ supervision\(service): \(notice.message)")
        }
        for project in snapshot.projects {
            for service in project.services {
                guard let health = service.health, health.isLive else { continue }
                let key = "\(project.projectID):\(service.service):\(service.index)"
                let value = health.state.rawValue
                guard healthByService[key] != value else { continue }
                healthByService[key] = value
                print("♥ \(service.service)-\(service.index) health: \(value)")
            }
        }
    }
}

private func runForegroundSupervision(
    project: ComposeProject,
    context: ComposeCLIContext,
    quiet: Bool
) async throws {
    let supervisor = ComposeSupervisor(
        runtime: context.runtime,
        store: context.store,
        stateCoordinator: context.stateCoordinator
    )
    let reporter = ComposeForegroundReporter()
    let (events, continuation) = AsyncStream.makeStream(
        of: RuntimeEvent.self,
        bufferingPolicy: .bufferingNewest(32)
    )
    let logs = try await project.logs(ProjectLogQuery(follow: true, tail: 100))

    if !quiet {
        print("Attached: logs, healthchecks, restart policies, and drift reporting are active. Press Ctrl-C to stop watching.")
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            defer { continuation.finish() }
            var wasUnavailable = false
            while !Task.isCancelled {
                do {
                    let containers = try await context.runtime.listContainers(all: true)
                    if wasUnavailable {
                        continuation.yield(.runtimeBecameAvailable)
                        wasUnavailable = false
                    }
                    continuation.yield(.snapshot(containers))
                } catch is CancellationError {
                    return
                } catch {
                    wasUnavailable = true
                    continuation.yield(.runtimeBecameUnavailable(message: error.localizedDescription))
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
        group.addTask {
            try await supervisor.run(events: events) { snapshot in
                await reporter.consume(snapshot)
            }
        }
        group.addTask {
            for try await entry in logs {
                print("\(entry.service)-\(entry.index) | \(entry.line.text)")
            }
        }
        defer { group.cancelAll() }
        try await group.waitForAll()
    }
}

struct ComposeProgressOptions: ParsableArguments {
    @Flag(name: .customLong("quiet"), help: "Suppress progress output.")
    var quiet = false
}

func drainComposeEvents(
    _ stream: AsyncThrowingStream<ComposeEvent, Error>,
    quiet: Bool,
    renderer suppliedRenderer: ComposeProgressRenderer? = nil
) async throws {
    var renderer = suppliedRenderer ?? .standard()
    defer { renderer.finish() }
    for try await event in stream {
        guard !quiet else { continue }
        renderer.consume(event)
    }
}

struct ComposeConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Resolve and validate the Compose configuration.")
    @OptionGroup var options: ComposeFileOptions
    @Flag(name: .customLong("report"), help: "Print the supported/unsupported key report.") var report = false

    /// Config resolution is deliberately runtime-free: it must work before
    /// Apple `container` is installed or while the runtime is stopped.
    func resolveDocument() throws -> ComposeDocument {
        try ComposeParser().parse(source: options.loadSource())
    }

    func run() async throws {
        let document = try resolveDocument()
        print(try ComposePresentation.resolvedConfiguration(document))
        if report {
            print(ComposePresentation.serviceDiscoveryExplanation)
            print(document.support.rendered)
        } else if !document.support.findings.isEmpty {
            print(document.support.rendered)
        }
        if document.support.hasFatalFindings { throw ExitCode.failure }
    }
}

struct ComposePlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Print the exact execution plan without running it.")
    @OptionGroup var options: ComposeFileOptions
    @Flag(name: .customLong("build")) var build = false
    @Flag(name: .customLong("force-recreate")) var forceRecreate = false
    @Flag(name: .customLong("no-deps")) var noDependencies = false
    @Argument var services: [String] = []

    func run() async throws {
        let prepared = try await openProject(options).prepareUp(UpRequest(
            services: services, build: build, forceRecreate: forceRecreate, noDependencies: noDependencies
        ))
        print("plan for project \(prepared.document.projectName):")
        print(prepared.plan.rendered)
    }
}

struct ComposeUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Create and start project services; attach supervision unless detached."
    )
    @OptionGroup var options: ComposeFileOptions
    @OptionGroup var progress: ComposeProgressOptions
    @Flag(name: [.customShort("d"), .customLong("detach")]) var detach = false
    @Flag(name: .customLong("build")) var build = false
    @Flag(name: .customLong("force-recreate")) var forceRecreate = false
    @Flag(name: .customLong("no-deps")) var noDependencies = false
    @Argument var services: [String] = []

    func run() async throws {
        let context = try ComposeCLIContext()
        let project = try await context.open(options)
        let prepared = try await project.prepareUp(UpRequest(
            services: services, build: build, forceRecreate: forceRecreate, noDependencies: noDependencies
        ))
        if !prepared.document.support.findings.isEmpty {
            print(prepared.document.support.rendered)
        }
        try await drainComposeEvents(project.up(prepared), quiet: progress.quiet)
        if detach {
            print("supervision requires the Capsule agent")
        } else {
            try await runForegroundSupervision(
                project: project,
                context: context,
                quiet: progress.quiet
            )
        }
    }
}

struct ComposeDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove project resources.")
    @OptionGroup var options: ComposeFileOptions
    @OptionGroup var progress: ComposeProgressOptions
    @Flag(name: .customLong("volumes")) var volumes = false
    @Flag(name: .customLong("remove-orphans")) var removeOrphans = false
    func run() async throws {
        let stream = try await openProject(options).down(DownRequest(removeVolumes: volumes, removeOrphans: removeOrphans))
        try await drainComposeEvents(stream, quiet: progress.quiet)
    }
}

struct ComposePsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List project services.")
    @OptionGroup var options: ComposeFileOptions
    func run() async throws {
        let status = try await openProject(options).status()
        print("SERVICE\tINDEX\tSTATE\tHEALTH\tCONTAINER")
        for service in status.services {
            print("\(service.service)\t\(service.index)\t\(service.runtimeState.rawValue)\t\(service.health?.rawValue ?? "-")\t\(service.containerID ?? "-")")
        }
        if let drift = status.drift, !drift.isInSync {
            print("DRIFT\tSERVICE\tDETAIL")
            for finding in drift.findings {
                print("\(finding.kind.rawValue)\t\(finding.service)\t\(finding.message)")
            }
        }
    }
}

struct ComposeReconcileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reconcile",
        abstract: "Compare persisted desired state with runtime state and optionally heal safe drift."
    )
    @OptionGroup var options: ComposeFileOptions
    @Flag(name: .customLong("heal"), help: "Recreate missing/changed services and restore desired running state.")
    var heal = false

    func run() async throws {
        let context = try ComposeCLIContext()
        let project = try await context.open(options)
        let projectID = await project.configuration().projectName
        let supervisor = ComposeSupervisor(
            runtime: context.runtime,
            store: context.store,
            stateCoordinator: context.stateCoordinator
        )
        let snapshot = try await supervisor.send(.reconcile(
            projectID: projectID,
            mode: heal ? .heal : .reportOnly
        ))
        guard let result = snapshot.projects.first(where: { $0.projectID == projectID }) else {
            throw ComposeSupervisorError.projectNotFound(projectID)
        }
        if result.drift.isInSync {
            print("Project \(projectID) is in sync.")
        } else {
            print("KIND\tSERVICE\tDETAIL")
            for finding in result.drift.findings {
                print("\(finding.kind.rawValue)\t\(finding.service)\t\(finding.message)")
            }
            if !heal {
                print("No changes made. Re-run with --heal to repair safe drift; orphans require explicit compose down --remove-orphans.")
            }
        }
    }
}

struct ComposeLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Read or follow project logs.")
    @OptionGroup var options: ComposeLogsFileOptions
    @Flag(name: [.customShort("f"), .customLong("follow")]) var follow = false
    @Option(name: [.customShort("n"), .customLong("tail")]) var tail: Int?
    @Argument var services: [String] = []
    func run() async throws {
        let stream = try await openProject(options).logs(ProjectLogQuery(
            selection: ServiceSelection(services), follow: follow, tail: tail
        ))
        for try await entry in stream { print("\(entry.service)-\(entry.index) | \(entry.line.text)") }
    }
}

private protocol ComposeServiceOperationCommand: AsyncParsableCommand {
    var options: ComposeFileOptions { get }
    var progress: ComposeProgressOptions { get }
    var services: [String] { get }
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error>
}

extension ComposeServiceOperationCommand {
    func run() async throws {
        let stream = try await operation(openProject(options), ServiceSelection(services))
        try await drainComposeEvents(stream, quiet: progress.quiet)
    }
}

struct ComposeStartCommand: ComposeServiceOperationCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start existing project services.")
    @OptionGroup var options: ComposeFileOptions; @OptionGroup var progress: ComposeProgressOptions; @Argument var services: [String] = []
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error> { try await project.start(selection) }
}
struct ComposeStopCommand: ComposeServiceOperationCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop project services.")
    @OptionGroup var options: ComposeFileOptions; @OptionGroup var progress: ComposeProgressOptions; @Argument var services: [String] = []
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error> { try await project.stop(selection) }
}
struct ComposeRestartCommand: ComposeServiceOperationCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart project services.")
    @OptionGroup var options: ComposeFileOptions; @OptionGroup var progress: ComposeProgressOptions; @Argument var services: [String] = []
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error> { try await project.restart(selection) }
}
struct ComposeBuildCommand: ComposeServiceOperationCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build service images.")
    @OptionGroup var options: ComposeFileOptions; @OptionGroup var progress: ComposeProgressOptions; @Argument var services: [String] = []
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error> { try await project.build(selection) }
}
struct ComposePullCommand: ComposeServiceOperationCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull service images.")
    @OptionGroup var options: ComposeFileOptions; @OptionGroup var progress: ComposeProgressOptions; @Argument var services: [String] = []
    func operation(_ project: ComposeProject, _ selection: ServiceSelection) async throws -> AsyncThrowingStream<ComposeEvent, Error> { try await project.pull(selection) }
}

struct ComposeExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Run a non-interactive command in a service container.")
    @OptionGroup var options: ComposeFileOptions
    @Argument var service: String
    @Argument(parsing: .captureForPassthrough) var command: [String]
    func run() async throws {
        guard !command.isEmpty else { throw ValidationError("exec requires a command") }
        let result = try await openProject(options).exec(service: service, argv: command)
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }
}
