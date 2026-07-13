import ContainerClientTestSupport
import Foundation
import Testing
@testable import ContainerClient

@Test func resourceInventoryDerivesReverseReferencesOwnersAndBuiltInNetworks() {
    let web = ContainerDetail(
        id: "demo-web-1",
        status: "running",
        labels: ["capsule.project": "demo", "capsule.service": "web"],
        requestedNetworks: ["demo_default"],
        networks: [NetworkAttachment(network: "demo_default")],
        mounts: [
            MountDetail(
                destination: "/data",
                source: "demo_data",
                options: [],
                kind: .volume(name: "demo_data")
            ),
        ]
    )
    let external = ContainerDetail(
        id: "manual",
        status: "stopped",
        requestedNetworks: ["default"],
        mounts: [
            MountDetail(
                destination: "/cache",
                source: "shared_cache",
                options: [],
                kind: .volume(name: nil)
            ),
        ]
    )

    let inventory = RuntimeResourceInventory(
        volumes: [
            VolumeSummary(name: "shared_cache"),
            VolumeSummary(name: "demo_data", labels: ["capsule.project": "demo"]),
        ],
        networks: [
            NetworkSummary(
                name: "default",
                labels: ["com.apple.container.resource.role": "builtin"]
            ),
            NetworkSummary(name: "demo_default", labels: ["capsule.project": "demo"]),
        ],
        containerDetails: [external, web]
    )

    #expect(inventory.volume(named: "demo_data")?.usedBy.map(\.id) == ["demo-web-1"])
    #expect(inventory.volume(named: "demo_data")?.owner == .capsule(project: "demo"))
    #expect(inventory.volume(named: "shared_cache")?.usedBy.map(\.id) == ["manual"])
    #expect(inventory.volume(named: "shared_cache")?.owner == .external)
    #expect(inventory.network(named: "demo_default")?.connectedContainers.map(\.id) == ["demo-web-1"])
    #expect(inventory.network(named: "default")?.connectedContainers.map(\.id) == ["manual"])
    #expect(inventory.network(named: "default")?.owner == .system)
    #expect(inventory.network(named: "default")?.isBuiltIn == true)
    #expect(inventory.network(named: "missing") == nil)
}

@Test func resourceInventoryLoadsListsAndInspectsThroughRuntimeProtocol() async throws {
    let fake = FakeContainerRuntime()
    await fake.setVolumes([VolumeSummary(name: "demo_data")])
    await fake.setNetworks([NetworkSummary(name: "demo_default")])
    await fake.setContainers([
        ContainerSummary(id: "demo-web-1", status: "running", imageReference: nil, addresses: []),
    ])
    await fake.setDetail(
        ContainerDetail(
            id: "demo-web-1",
            status: "running",
            requestedNetworks: ["demo_default"],
            mounts: [
                MountDetail(
                    destination: "/data",
                    source: "demo_data",
                    options: [],
                    kind: .volume(name: "demo_data")
                ),
            ]
        ),
        forID: "demo-web-1"
    )

    let inventory = try await RuntimeResourceInventory.load(from: fake)
    #expect(inventory.volume(named: "demo_data")?.usedBy.map(\.id) == ["demo-web-1"])
    #expect(inventory.network(named: "demo_default")?.connectedContainers.map(\.id) == ["demo-web-1"])

    let calls = await fake.calls
    #expect(calls.contains(.listContainers(all: true)))
    #expect(calls.contains(.listVolumes))
    #expect(calls.contains(.listNetworks))
    #expect(calls.contains(.inspectContainer(id: "demo-web-1")))
}

@Test func containerDetailDecodesRequestedNetworksForStoppedInventoryRows() throws {
    let json = Data("""
    [{"id":"demo-web-1","status":{"state":"stopped","networks":[]},"configuration":{"networks":[{"network":"demo_default","options":{"hostname":"web"}}]}}]
    """.utf8)
    let details = try RuntimeJSON.makeDecoder().decode([ContainerDetail].self, from: json)
    #expect(details.first?.requestedNetworks == ["demo_default"])
}

@Test func resourceInventoryToleratesTypedListToInspectDeletionChurn() async throws {
    let fake = FakeContainerRuntime()
    await fake.setVolumes([VolumeSummary(name: "data")])
    await fake.setContainers([ContainerSummary(
        id: "gone", status: "running", imageReference: nil, addresses: []
    )])
    await fake.setError(RuntimeError.resourceNotFound(kind: "container", id: "gone"), for: .inspectContainer)

    let inventory = try await RuntimeResourceInventory.load(from: fake)
    #expect(inventory.volume(named: "data")?.usedBy.isEmpty == true)
}
