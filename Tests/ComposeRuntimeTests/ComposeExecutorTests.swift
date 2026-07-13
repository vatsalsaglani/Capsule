import ComposePlanner
import ComposeRuntime
import ContainerClient
import ContainerClientTestSupport
import Foundation
import Testing

@Test func executorRunsParallelLayersAndEmitsOperationScopedProgress() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setPullEvents([PullProgress(message: "pulled")], forReference: "nginx:latest")
    let network = NetworkCreateSpec(name: "demo_default", labels: ["capsule.project": "demo"])
    let volume = VolumeCreateSpec(name: "demo_data", labels: ["capsule.project": "demo"])
    var runSpec = RunSpec(image: "nginx:latest")
    runSpec.name = "demo-web-1"
    runSpec.labels = [
        "capsule.project": "demo",
        "capsule.service": "web",
        "capsule.index": "1",
        "capsule.config-hash": "hash",
    ]
    let plan = ExecutionPlan(layers: [
        PlanLayer(steps: [
            .ensureNetwork(network),
            .ensureVolume(volume),
            .ensureImage(service: "web", image: "nginx:latest", platform: nil),
        ]),
        PlanLayer(steps: [.ensureContainer(service: "web", spec: runSpec)]),
        PlanLayer(steps: [.start(service: "web", containerReference: "demo-web-1")]),
    ])

    let executor = ComposeExecutor(runtime: runtime)
    let stream = await executor.execute(plan)
    var events: [ComposeEvent] = []
    for try await event in stream { events.append(event) }

    let calls = await runtime.calls
    #expect(calls.contains(.createNetwork(network)))
    #expect(calls.contains(.createVolume(volume)))
    #expect(calls.contains(.pullImage(reference: "nginx:latest", platform: nil)))
    #expect(calls.contains(.createContainer(runSpec)))
    #expect(calls.contains(.startContainer(id: "demo-web-1")))
    #expect(events.contains { if case .stepOutput(_, "pulled") = $0 { true } else { false } })
    #expect(events.contains { if case .operationCompleted(_, .up) = $0 { true } else { false } })
}

@Test func executorRefreshesHostsWithResolvedPeerIPsWithoutShellInterpolation() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setDetail(
        ContainerDetail(
            id: "demo-db-1",
            status: "running",
            networks: [NetworkAttachment(ipv4Address: "192.168.65.4/24", network: "demo_default")]
        ),
        forID: "demo-db-1"
    )
    await runtime.setExecResult(
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data()),
        forID: "demo-api-1"
    )
    let target = ServiceHostTarget(
        service: "api",
        containerReference: "demo-api-1",
        peers: [
            ServiceHostPeer(
                service: "db",
                containerReference: "demo-db-1",
                aliases: ["db", "demo-db-1", "bad alias;ignored"]
            ),
        ]
    )
    let executor = ComposeExecutor(runtime: runtime)
    for try await _ in await executor.execute(
        ExecutionPlan(layers: [PlanLayer(steps: [.refreshHosts(targets: [target])])])
    ) {}

    let calls = await runtime.calls
    let execCall = try #require(calls.first { if case .execWithOptions = $0 { true } else { false } })
    guard case .execWithOptions(let id, let argv, let options, _) = execCall else { return }
    #expect(id == "demo-api-1")
    #expect(options == .containerRoot)
    #expect(argv.prefix(2) == ["sh", "-c"])
    #expect(argv.last == "192.168.65.4 db demo-db-1")
    let script = argv[2]
    #expect(script.contains("umask 077"))
    #expect(script.contains("tmp=''"))
    #expect(script.contains("while [ \"$i\" -lt 32 ]"))
    #expect(script.contains("candidate=\"${TMPDIR:-/tmp}/capsule-hosts.$$.$i\""))
    #expect(script.contains("(set -C; : > \"$candidate\") 2>/dev/null"))
    #expect(script.contains("trap 'rm -f \"$tmp\"' 0 1 2 3 15"))
    #expect(!script.contains("tmp=\"/tmp/capsule-hosts.$$\""))
    #expect(script.contains("printf '%s\\n' '# capsule:begin' \"$1\" '# capsule:end' >> \"$tmp\""))
    #expect(!script.contains("demo-db-1"))
    #expect(script.contains("cat \"$tmp\" > /etc/hosts"))
    #expect(!script.contains("mv "))
}

@Test func ensureImageSkipsPullWhenExactReferenceAlreadyExists() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setImages([ImageSummary(id: "existing", reference: "nginx:latest")])
    let step = PlanStep.ensureImage(service: "web", image: "nginx:latest", platform: nil)
    let executor = ComposeExecutor(runtime: runtime)
    var events: [ComposeEvent] = []
    for try await event in await executor.execute(ExecutionPlan(steps: [step])) {
        events.append(event)
    }

    let calls = await runtime.calls
    #expect(calls.contains(.listImages))
    #expect(!calls.contains(.pullImage(reference: "nginx:latest", platform: nil)))
    #expect(events.contains { if case .stepOutput(_, "image nginx:latest already present") = $0 { true } else { false } })
}

@Test func ensureImagePullsWhenOnlyADifferentReferenceExists() async throws {
    let runtime = FakeContainerRuntime()
    await runtime.setImages([ImageSummary(id: "other", reference: "nginx:stable")])
    await runtime.setPullEvents([PullProgress(message: "pulled")], forReference: "nginx:latest")
    let executor = ComposeExecutor(runtime: runtime)
    for try await _ in await executor.execute(ExecutionPlan(steps: [
        .ensureImage(service: "web", image: "nginx:latest", platform: nil),
    ])) {}

    #expect(await runtime.calls.contains(.pullImage(reference: "nginx:latest", platform: nil)))
}
