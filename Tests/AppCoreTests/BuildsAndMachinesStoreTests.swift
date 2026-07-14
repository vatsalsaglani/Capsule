import AppCore
import ContainerClient
import ContainerClientTestSupport
import Testing

@Test func machineCreationInputValidatesAndConvertsGiBWithoutFrontendMath() throws {
    let input = MachineCreationInput(
        imageReference: " alpine:3.22 ",
        name: " dev ",
        platform: " linux/arm64 ",
        cpus: 4,
        memoryGiB: 8,
        homeMount: .readOnly,
        bootAfterCreation: false,
        setAsDefault: true,
        nestedVirtualization: true
    )

    #expect(try input.spec() == MachineCreateSpec(
        imageReference: "alpine:3.22",
        name: "dev",
        platform: "linux/arm64",
        cpus: 4,
        memoryBytes: 8_589_934_592,
        homeMount: .readOnly,
        bootAfterCreation: false,
        setAsDefault: true,
        nestedVirtualization: true
    ))
    #expect(throws: MachineCreationInputError.self) {
        try MachineCreationInput(imageReference: "  ").spec()
    }
}

@MainActor
@Test func machinesStoreLoadsInspectsControlsAndStreamsLogsThroughRuntime() async throws {
    let runtime = FakeContainerRuntime()
    let summary = MachineSummary(
        id: "dev-machine",
        state: .stopped,
        isDefault: true,
        cpus: 4,
        memoryBytes: 8_589_934_592
    )
    let detail = MachineDetail(
        id: summary.id,
        imageReference: "alpine:3.22",
        operatingSystem: "linux",
        architecture: "arm64",
        state: .stopped,
        cpus: summary.cpus,
        memoryBytes: summary.memoryBytes,
        homeMount: .readWrite
    )
    await runtime.setMachines([summary])
    await runtime.setMachineDetail(detail, forID: summary.id)
    await runtime.setMachineLogLines([LogLine(text: "machine ready")], forID: summary.id)
    let store = MachinesStore(runtime: runtime)

    await store.refresh()
    await store.select(id: summary.id)
    await store.start(id: summary.id)
    await store.showLogs(id: summary.id, source: .boot)

    #expect(store.machines == [summary])
    #expect(store.selectedDetail == detail)
    #expect(store.logLines.map(\.text) == ["machine ready"])
    let calls = await runtime.calls
    #expect(calls.contains(.inspectMachine(id: summary.id)))
    #expect(calls.contains(.startMachine(id: summary.id)))
    #expect(calls.contains(.machineLogs(id: summary.id, source: .boot, follow: true, tail: 300)))
    store.stopLogs()
}
