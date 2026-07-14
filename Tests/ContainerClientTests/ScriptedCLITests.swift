import Foundation
import Testing
@testable import ContainerClient

/// `CLIProcessClient(binaryPath:)` against small shell scripts standing in
/// for `container`, emulating the exact live-probed output shapes
/// (`docs/learnings/2026-07-12-runtime-cli-observations.md`) without
/// depending on the real runtime being installed.
private enum ScriptedBinary {
    /// Writes `contents` to a fresh temp file, marks it executable, and
    /// returns its path. Each call gets its own throwaway directory so
    /// parallel tests never collide.
    static func write(_ contents: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsule-scripted-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("fake-container").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    /// A path inside a fresh throwaway directory a script can write its
    /// received argv to, for tests that need to assert exact arguments.
    static func freshCapturePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsule-scripted-cli-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("argv.txt").path
    }
}

@Test func createContainerParsesStdoutIDAmidStderrProgressNoise() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    echo "[1/6] preparing" 1>&2
    echo "[6/6] done" 1>&2
    echo "  container-abc123  "
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let id = try await client.createContainer(RunSpec(image: "docker.io/library/nginx:latest"))
    #expect(id == "container-abc123")
}

@Test func execReturnsNonZeroExitCodeAsALegitimateResultNotAThrow() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    echo "out"
    echo "err" 1>&2
    exit 7
    """)
    let client = try CLIProcessClient(binaryPath: script)
    // A generous timeout — this only needs to bound a genuine hang, not race
    // real work; a tight bound here is just flakiness risk under transient
    // system load for no test-quality benefit.
    let result = try await client.exec(id: "web-1", argv: ["sh", "-c", "exit 7"], timeout: .seconds(20))
    #expect(result.exitCode == 7)
    #expect(result.stdoutText == "out\n")
    #expect(result.stderrText == "err\n")
}

@Test func argvEchoExecDefaultIdentityRemainsByteForByteUnchanged() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    _ = try await client.exec(
        id: "web-1",
        argv: ["sh", "-c", "id -u"],
        timeout: .seconds(20)
    )

    #expect(try String(contentsOfFile: capture, encoding: .utf8) == """
    exec
    web-1
    sh
    -c
    id -u

    """)
}

@Test func argvEchoExecContainerRootPrecedesIDAndPreservesNonZeroResult() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo 'root command failed' 1>&2
    exit 9
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let result = try await client.exec(
        id: "adminer-1",
        argv: ["sh", "-c", "id -u"],
        options: .containerRoot,
        timeout: .seconds(20)
    )

    #expect(result.exitCode == 9)
    #expect(result.stderrText == "root command failed\n")
    #expect(try String(contentsOfFile: capture, encoding: .utf8) == """
    exec
    --user
    0
    adminer-1
    sh
    -c
    id -u

    """)
}

@Test func pullImageStreamsStderrThenThrowsWithTailOnNonZeroExit() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    echo "[1/2] Fetching image 10% (5 of 56 blobs, 2.1/28.8 MB, 1.2 MB/s) [3s]" 1>&2
    echo "[2/2] Fetching image 49% (31 of 56 blobs, 14.3/28.8 MB, 5.7 MB/s) [9s]" 1>&2
    echo "Error: registry unreachable" 1>&2
    exit 1
    """)
    let client = try CLIProcessClient(binaryPath: script)
    var messages: [String] = []
    do {
        for try await progress in try await client.pullImage(reference: "docker.io/library/nginx:latest", platform: nil) {
            messages.append(progress.message)
        }
        Issue.record("expected pullImage to throw on a non-zero exit")
    } catch let error as RuntimeError {
        guard case .commandFailed(_, let exitCode, _) = error else {
            Issue.record("unexpected RuntimeError case: \(error)")
            return
        }
        #expect(exitCode == 1)
    }
    // All three stderr lines are yielded as progress messages — a line
    // reader can't distinguish "the runtime's final error line" from
    // ordinary progress lines on the same fd; the thrown
    // `RuntimeError.commandFailed` afterward is what actually signals
    // failure to the caller.
    #expect(messages == [
        "[1/2] Fetching image 10% (5 of 56 blobs, 2.1/28.8 MB, 1.2 MB/s) [3s]",
        "[2/2] Fetching image 49% (31 of 56 blobs, 14.3/28.8 MB, 5.7 MB/s) [9s]",
        "Error: registry unreachable",
    ])
}

@Test func logsFinishesCleanlyOnZeroExit() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    echo "starting up"
    echo "ready"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    var lines: [String] = []
    for try await line in try await client.logs(id: "web-1", follow: false, tail: nil) {
        lines.append(line.text)
    }
    #expect(lines == ["starting up", "ready"])
}

@Test func inspectContainerDecodesSingleElementFromArrayResponse() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    cat <<'JSON'
    [{"id":"web-1","status":{"state":"running"},"configuration":{"id":"web-1"}}]
    JSON
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let detail = try await client.inspectContainer(id: "web-1")
    #expect(detail.id == "web-1")
    #expect(detail.status == "running")
}

@Test func inspectContainerThrowsDecodingFailedOnEmptyArray() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    echo "[]"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    await #expect(throws: RuntimeError.self) {
        _ = try await client.inspectContainer(id: "missing")
    }
}

// MARK: - argv-echo: exact arguments sent for each command shape

@Test func argvEchoListContainersAppendsAllAndFormatJSON() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo '[]'
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    _ = try await client.listContainers(all: true)
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "list\n--all\n--format\njson\n")
}

@Test func argvEchoListContainersWithoutAllOmitsFlag() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo '[]'
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    _ = try await client.listContainers(all: false)
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "list\n--format\njson\n")
}

@Test func argvEchoInspectContainerNeverAppendsFormatJSON() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo '[{"id":"web-1","status":{"state":"running"},"configuration":{"id":"web-1"}}]'
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    _ = try await client.inspectContainer(id: "web-1")
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "inspect\nweb-1\n")
}

@Test func argvEchoCreateVolumeSortsLabelsAndAppendsInternalOnNetworkOnly() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    try await client.createVolume(name: "demo-vol", labels: ["capsule.service": "web", "capsule.project": "demo"])
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "volume\ncreate\n--label\ncapsule.project=demo\n--label\ncapsule.service=web\ndemo-vol\n")
}

@Test func argvEchoCreateNetworkAppendsInternalFlagWhenRequested() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    try await client.createNetwork(name: "demo_default", labels: [:], isInternal: true)
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "network\ncreate\n--internal\ndemo_default\n")
}

@Test func argvEchoKillContainerPassesSignalAndID() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    try await client.killContainer(id: "web-1", signal: "SIGTERM")
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "kill\n--signal\nSIGTERM\nweb-1\n")
}

@Test func argvEchoPullImageIncludesPlatformWhenProvided() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    for try await _ in try await client.pullImage(reference: "docker.io/library/alpine:latest", platform: "linux/arm64") {}
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "image\npull\n--progress\nplain\n--platform\nlinux/arm64\ndocker.io/library/alpine:latest\n")
}

@Test func argvEchoBuildImageUsesDeterministicFullSpecAndStreamsProgress() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo '#1 loading build definition'
    echo '#1 resolving base image' 1>&2
    echo '#2 DONE 0.1s'
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let spec = ImageBuildSpec(
        contextDirectory: URL(fileURLWithPath: "/tmp/demo"),
        dockerfile: URL(fileURLWithPath: "/tmp/demo/Containerfile"),
        tag: "demo/web:dev",
        arguments: ["Z_LAST": "2", "A_FIRST": "1"],
        target: "runtime",
        platform: "linux/arm64",
        labels: ["capsule.service": "web", "capsule.project": "demo"],
        cachePolicy: .noCache,
        baseImagePolicy: .pull
    )
    var messages: [String] = []
    for try await event in try await client.buildImage(spec) {
        messages.append(event.message)
    }

    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == """
    build
    --progress
    plain
    --tag
    demo/web:dev
    --file
    /tmp/demo/Containerfile
    --build-arg
    A_FIRST=1
    --build-arg
    Z_LAST=2
    --target
    runtime
    --platform
    linux/arm64
    --label
    capsule.project=demo
    --label
    capsule.service=web
    --no-cache
    --pull
    /tmp/demo

    """)
    #expect(messages == [
        "#1 loading build definition",
        "#1 resolving base image",
        "#2 DONE 0.1s",
    ])
}

@Test func argvEchoRichVolumeAndNetworkCreateSpecsMapCapacityConnectivityAndSubnets() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" >> "\(capture)"
    printf '%s\\n' --- >> "\(capture)"
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    try await client.createVolume(VolumeCreateSpec(
        name: "demo_data",
        capacityBytes: 1_073_741_824,
        labels: ["capsule.project": "demo"]
    ))
    try await client.createNetwork(NetworkCreateSpec(
        name: "demo_default",
        connectivity: .hostOnly,
        ipv4Subnet: "192.168.90.0/24",
        ipv6Subnet: "fd00:90::/64",
        labels: ["capsule.project": "demo"]
    ))

    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == """
    volume
    create
    --label
    capsule.project=demo
    -s
    1073741824
    demo_data
    ---
    network
    create
    --label
    capsule.project=demo
    --internal
    --subnet
    192.168.90.0/24
    --subnet-v6
    fd00:90::/64
    demo_default
    ---

    """)
}

@Test func volumePruneDerivesRemovedNamesFromBeforeAndAfterLists() async throws {
    let state = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    if [ "$1" = volume ] && [ "$2" = ls ]; then
      if [ -f "\(state)" ]; then
        echo '[{"configuration":{"name":"kept"}}]'
      else
        echo '[{"configuration":{"name":"kept"}},{"configuration":{"name":"removed"}}]'
      fi
      exit 0
    fi
    if [ "$1" = volume ] && [ "$2" = prune ]; then
      touch "\(state)"
      echo 'Removed unused volumes'
      exit 0
    fi
    exit 64
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let report = try await client.pruneVolumes()
    #expect(report.removedNames == ["removed"])
    #expect(report.notices == ["Removed unused volumes"])
}

@Test func networkPruneDerivesRemovedNamesFromBeforeAndAfterLists() async throws {
    let state = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    if [ "$1" = network ] && [ "$2" = ls ]; then
      if [ -f "\(state)" ]; then
        echo '[{"id":"default","configuration":{"name":"default","labels":{"com.apple.container.resource.role":"builtin"}}}]'
      else
        echo '[{"id":"default","configuration":{"name":"default","labels":{"com.apple.container.resource.role":"builtin"}}},{"id":"old_net","configuration":{"name":"old_net"}}]'
      fi
      exit 0
    fi
    if [ "$1" = network ] && [ "$2" = prune ]; then
      touch "\(state)"
      echo 'Removed unused networks' 1>&2
      exit 0
    fi
    exit 64
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let report = try await client.pruneNetworks()
    #expect(report.removedNames == ["old_net"])
    #expect(report.notices == ["Removed unused networks"])
}

@Test func argvEchoStatsUsesNoStreamPollShape() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capture)"
    echo '[]'
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script, statsInterval: .seconds(30))
    var ticks = 0
    for try await _ in try await client.stats(ids: ["web-1", "web-2"]) {
        ticks += 1
        if ticks == 1 { break }
    }
    let captured = try String(contentsOfFile: capture, encoding: .utf8)
    #expect(captured == "stats\n--no-stream\n--format\njson\nweb-1\nweb-2\n")
}

@Test func machineListAndInspectDecodeRuntimeOnePointOneJSON() async throws {
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    if [ "$1" = machine ] && [ "$2" = list ]; then
      echo '[{"id":"dev","status":"running","default":true,"ipAddress":"192.168.64.2","cpus":4,"memory":8589934592,"diskSize":107374182400,"createdDate":"2026-07-14T00:00:00Z"}]'
      exit 0
    fi
    if [ "$1" = machine ] && [ "$2" = inspect ]; then
      echo '[{"id":"dev","image":{"reference":"alpine:3.22"},"platform":{"os":"linux","architecture":"arm64"},"status":"running","startedDate":"2026-07-14T00:01:00Z","createdDate":"2026-07-14T00:00:00Z","containerId":"machine-dev","cpus":4,"memory":8589934592,"homeMount":"rw","diskSize":107374182400,"ipAddress":"192.168.64.2"}]'
      exit 0
    fi
    exit 64
    """)
    let client = try CLIProcessClient(binaryPath: script)
    let values = try await client.listMachines()
    let detail = try await client.inspectMachine(id: "dev")
    #expect(values.first?.id == "dev")
    #expect(values.first?.state == .running)
    #expect(values.first?.memoryBytes == 8_589_934_592)
    #expect(detail.imageReference == "alpine:3.22")
    #expect(detail.homeMount == .readWrite)
}

@Test func argvEchoMachineCreateStartAndLogsUseVerifiedRuntimeShapes() async throws {
    let capture = try ScriptedBinary.freshCapturePath()
    let script = try ScriptedBinary.write("""
    #!/bin/sh
    printf '%s\\n' "$@" >> "\(capture)"
    printf '%s\\n' --- >> "\(capture)"
    if [ "$1" = machine ] && [ "$2" = create ]; then echo dev-machine; fi
    if [ "$1" = machine ] && [ "$2" = logs ]; then echo ready; fi
    exit 0
    """)
    let client = try CLIProcessClient(binaryPath: script)
    _ = try await client.createMachine(MachineCreateSpec(
        imageReference: "alpine:3.22",
        name: "dev-machine",
        platform: "linux/arm64",
        cpus: 4,
        memoryBytes: 8_589_934_592,
        homeMount: .readOnly,
        bootAfterCreation: false,
        setAsDefault: true,
        nestedVirtualization: true
    ))
    try await client.startMachine(id: "dev-machine")
    for try await _ in try await client.machineLogs(id: "dev-machine", source: .boot, follow: true, tail: 50) {}

    #expect(try String(contentsOfFile: capture, encoding: .utf8) == """
    machine
    create
    --progress
    plain
    --name
    dev-machine
    --platform
    linux/arm64
    --cpus
    4
    --memory
    8589934592
    --home-mount
    ro
    --set-default
    --no-boot
    --virtualization
    alpine:3.22
    ---
    machine
    run
    --root
    --name
    dev-machine
    true
    ---
    machine
    logs
    --boot
    --follow
    -n
    50
    dev-machine
    ---

    """)
}
