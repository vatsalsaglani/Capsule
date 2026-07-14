import ArgumentParser
@testable import CapsuleCLI
import Foundation
import Testing

@Test func composeUpParsesDocumentedSelectionAndPlanningFlags() throws {
    let root = try CapsuleCommand.parseAsRoot([
        "compose", "up", "-f", "stack.yaml", "-d", "--build",
        "--force-recreate", "--no-deps", "--quiet", "web", "worker",
    ])
    let command = try #require(root as? ComposeUpCommand)
    #expect(command.options.file == "stack.yaml")
    #expect(command.detach)
    #expect(command.build)
    #expect(command.forceRecreate)
    #expect(command.noDependencies)
    #expect(command.progress.quiet)
    #expect(command.services == ["web", "worker"])
}

@Test func composeConfigReportAndExecRemainingArgumentsParse() throws {
    let configRoot = try CapsuleCommand.parseAsRoot(["compose", "config", "--report"])
    let config = try #require(configRoot as? ComposeConfigCommand)
    #expect(config.report)

    let execRoot = try CapsuleCommand.parseAsRoot([
        "compose", "exec", "web", "sh", "-c", "printf hello",
    ])
    let exec = try #require(execRoot as? ComposeExecCommand)
    #expect(exec.service == "web")
    #expect(exec.command == ["sh", "-c", "printf hello"])
}

@Test func composeConfigResolvesOfflineThroughItsParserOnlySeam() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capsule-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("offline.yaml")
    try "services:\n  app: { image: alpine }\n".write(to: file, atomically: true, encoding: .utf8)

    let root = try CapsuleCommand.parseAsRoot([
        "compose", "config", "--file", file.path, "--project-name", "offline",
    ])
    let command = try #require(root as? ComposeConfigCommand)
    let document = try command.resolveDocument()
    #expect(document.projectName == "offline")
    #expect(document.file.services["app"]?.image == "alpine")
}

@Test func allComposeServiceCommandsAreRegistered() throws {
    #expect(try CapsuleCommand.parseAsRoot(["compose", "start", "web"]) is ComposeStartCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "stop", "web"]) is ComposeStopCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "restart", "web"]) is ComposeRestartCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "build", "web"]) is ComposeBuildCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "pull", "web"]) is ComposePullCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "logs", "-f", "web"]) is ComposeLogsCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "ps"]) is ComposePsCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "down", "--volumes"]) is ComposeDownCommand)
    #expect(try CapsuleCommand.parseAsRoot(["compose", "plan"]) is ComposePlanCommand)
    let reconcile = try #require(
        try CapsuleCommand.parseAsRoot(["compose", "reconcile", "--heal"])
            as? ComposeReconcileCommand
    )
    #expect(reconcile.heal)
}

@Test func quietParsesAcrossEventStreamingCommands() throws {
    let down = try #require(try CapsuleCommand.parseAsRoot(["compose", "down", "--quiet"]) as? ComposeDownCommand)
    #expect(down.progress.quiet)
    let start = try #require(try CapsuleCommand.parseAsRoot(["compose", "start", "--quiet", "web"]) as? ComposeStartCommand)
    #expect(start.progress.quiet)
    let build = try #require(try CapsuleCommand.parseAsRoot(["compose", "build", "--quiet"]) as? ComposeBuildCommand)
    #expect(build.progress.quiet)
}

@Test func volumeAndNetworkCommandsParseRichCreateOptionsAndAliases() throws {
    let volumeRoot = try CapsuleCommand.parseAsRoot([
        "volumes", "create", "data", "--capacity", "4096",
        "--label", "team=platform", "--label", "tier=state",
    ])
    let volume = try #require(volumeRoot as? VolumeCreateCommand)
    #expect(volume.name == "data")
    #expect(volume.capacityBytes == 4096)
    #expect(volume.labels == ["team=platform", "tier=state"])

    let networkRoot = try CapsuleCommand.parseAsRoot([
        "networks", "create", "private", "--internal", "--subnet", "10.42.0.0/24",
        "--subnet-v6", "fd00:42::/64", "--label", "scope=test",
    ])
    let network = try #require(networkRoot as? NetworkCreateCommand)
    #expect(network.name == "private")
    #expect(network.isInternal)
    #expect(network.ipv4Subnet == "10.42.0.0/24")
    #expect(network.ipv6Subnet == "fd00:42::/64")
    #expect(try CapsuleCommand.parseAsRoot(["volumes", "ls"]) is VolumeListCommand)
    #expect(try CapsuleCommand.parseAsRoot(["networks", "rm", "private"]) is NetworkDeleteCommand)
}

@Test func irreversibleVolumeCommandsRequireScriptableForceFlag() throws {
    let delete = try #require(try CapsuleCommand.parseAsRoot(["volumes", "rm", "data", "--force"]) as? VolumeDeleteCommand)
    #expect(delete.force)
    let prune = try #require(try CapsuleCommand.parseAsRoot(["volumes", "prune", "--force"]) as? VolumePruneCommand)
    #expect(prune.force)
}

@Test func resourceLabelsValidateAndUseLastDuplicate() throws {
    #expect(try ResourceCommandRendering.labels(["a=1", "a=2", "empty="]) == ["a": "2", "empty": ""])
    #expect(throws: (any Error).self) {
        try ResourceCommandRendering.labels(["missing-separator"])
    }
}

@Test func directBuildBuilderAndMachineCommandsParseTheirPublicOptions() throws {
    let build = try #require(try CapsuleCommand.parseAsRoot([
        "build", "/tmp/context", "--tag", "demo:dev", "--tag", "demo:latest",
        "--file", "/tmp/context/Containerfile", "--build-arg", "TOKEN=value",
        "--platform", "linux/arm64", "--target", "runtime", "--no-cache", "--pull",
    ]) as? DirectBuildCommand)
    #expect(build.context == "/tmp/context")
    #expect(build.tag == ["demo:dev", "demo:latest"])
    #expect(build.buildArguments == ["TOKEN=value"])
    #expect(build.noCache && build.pull)

    #expect(try CapsuleCommand.parseAsRoot(["builder", "status"]) is BuilderStatusCommand)
    let machine = try #require(try CapsuleCommand.parseAsRoot([
        "machines", "create", "alpine:3.22", "--name", "dev-machine",
        "--cpus", "4", "--memory-bytes", "8589934592", "--home-mount", "ro",
        "--no-boot", "--set-default", "--nested-virtualization",
    ]) as? MachineCreateCommand)
    #expect(machine.image == "alpine:3.22")
    #expect(machine.name == "dev-machine")
    #expect(machine.cpus == 4)
    #expect(machine.memoryBytes == 8_589_934_592)
    #expect(machine.homeMount == "ro")
    #expect(machine.noBoot && machine.setDefault && machine.nestedVirtualization)
    #expect(try CapsuleCommand.parseAsRoot(["machines", "logs", "--boot", "-f", "dev-machine"]) is MachineLogsCommand)
    let delete = try #require(try CapsuleCommand.parseAsRoot(["machines", "rm", "dev-machine", "--force"]) as? MachineDeleteCommand)
    #expect(delete.force)
}
