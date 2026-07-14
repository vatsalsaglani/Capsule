import ArgumentParser

@main
struct CapsuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capsule",
        abstract: "Manage Apple `container` workloads and compose-style projects.",
        discussion: """
        Companion CLI to Capsule.app. Flag names and exit codes mirror \
        `docker compose` where the semantics genuinely match — never beyond.
        """,
        version: "0.1.0-beta",
        subcommands: [
            ComposeCommand.self,
            DirectBuildCommand.self,
            BuilderCommand.self,
            MachinesCommand.self,
            VolumesCommand.self,
            NetworksCommand.self,
            ListCommand.self,
            DoctorCommand.self,
            RuntimeCommand.self,
        ]
    )
}
