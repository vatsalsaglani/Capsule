import ArgumentParser
import ComposePlanner
import ComposeSpec
import Foundation

struct ComposeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Compose-style multi-container projects on Apple `container`.",
        subcommands: [
            ComposeConfigCommand.self,
            ComposePlanCommand.self,
            ComposeUpCommand.self,
            ComposeDownCommand.self,
            ComposePsCommand.self,
            ComposeLogsCommand.self,
        ]
    )
}

struct ComposeFileOptions: ParsableArguments {
    @Option(
        name: [.customShort("f"), .customLong("file")],
        help: "Compose file (default: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml)."
    )
    var file: String?

    @Option(
        name: [.customShort("p"), .customLong("project-name")],
        help: "Project name (default: the file's `name:`, else the directory name)."
    )
    var projectName: String?

    func loadDocument() throws -> ComposeDocument {
        try ComposeParser().parse(fileAt: resolveFileURL(), projectName: projectName)
    }

    private func resolveFileURL() throws -> URL {
        if let file {
            let url = URL(fileURLWithPath: file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("compose file not found: \(file)")
            }
            return url
        }
        for candidate in ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ValidationError("no compose file found in the current directory; pass -f <path>")
    }
}

struct ComposeConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Parse and validate the compose file; print the support report."
    )

    @OptionGroup var options: ComposeFileOptions

    func run() async throws {
        let document = try options.loadDocument()
        print("project: \(document.projectName)")
        for (name, service) in document.file.services.sorted(by: { $0.key < $1.key }) {
            var facts: [String] = []
            if let image = service.image { facts.append("image=\(image)") }
            if let build = service.build { facts.append("build=\(build.context)") }
            if let ports = service.ports, !ports.isEmpty {
                facts.append("ports=" + ports.map {
                    "\($0.published.map(String.init) ?? "?"):\($0.target)/\($0.proto)"
                }.joined(separator: ","))
            }
            if let deps = service.dependsOn?.requirements.keys.sorted(), !deps.isEmpty {
                facts.append("depends_on=" + deps.joined(separator: ","))
            }
            if service.healthcheck != nil { facts.append("healthcheck") }
            print("  \(name): \(facts.joined(separator: " "))")
        }
        print(document.support.rendered)
        if document.support.hasFatalFindings {
            throw ExitCode(1)
        }
    }
}

struct ComposePlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Print the execution plan without running it."
    )

    @OptionGroup var options: ComposeFileOptions

    func run() async throws {
        let document = try options.loadDocument()
        if !document.support.findings.isEmpty {
            print(document.support.rendered)
            print("")
        }
        let plan = try Planner().makePlan(for: document)
        print("plan for project \(document.projectName):")
        print(plan.rendered)
    }
}

private func notImplemented(_ command: String, milestone: String) -> Error {
    print("`capsule compose \(command)` lands in \(milestone) — see docs/ROADMAP.md.")
    return ExitCode(2)
}

struct ComposeUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Create and start the project (M2).")
    @OptionGroup var options: ComposeFileOptions
    func run() async throws { throw notImplemented("up", milestone: "M2") }
}

struct ComposeDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove the project (M2).")
    @OptionGroup var options: ComposeFileOptions
    func run() async throws { throw notImplemented("down", milestone: "M2") }
}

struct ComposePsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List project containers (M2).")
    @OptionGroup var options: ComposeFileOptions
    func run() async throws { throw notImplemented("ps", milestone: "M2") }
}

struct ComposeLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Stream project logs (M2).")
    @OptionGroup var options: ComposeFileOptions
    func run() async throws { throw notImplemented("logs", milestone: "M2") }
}
