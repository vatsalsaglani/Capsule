import Foundation
import Testing
@testable import ContainerClient

@Test func runSpecDefaultsMatchInit() {
    let spec = RunSpec(image: "docker.io/library/nginx:latest")
    #expect(spec.image == "docker.io/library/nginx:latest")
    #expect(spec.name == nil)
    #expect(spec.command.isEmpty)
    #expect(spec.entrypoint == nil)
    #expect(spec.environment.isEmpty)
    #expect(spec.workingDirectory == nil)
    #expect(spec.user == nil)
    #expect(spec.ports.isEmpty)
    #expect(spec.mounts.isEmpty)
    #expect(spec.networks.isEmpty)
    #expect(spec.platform == nil)
    #expect(spec.rosetta == false)
    #expect(spec.useInit == false)
    #expect(spec.labels.isEmpty)
    #expect(spec.dns == nil)
    #expect(spec.readOnly == false)
    #expect(spec.shmSize == nil)
}

@Test func runSpecCodableRoundTrips() throws {
    var spec = RunSpec(image: "docker.io/library/nginx:latest")
    spec.name = "web"
    spec.command = ["nginx", "-g", "daemon off;"]
    spec.entrypoint = "/bin/sh"
    spec.environment = ["FOO": "bar"]
    spec.workingDirectory = "/app"
    spec.user = "www-data"
    spec.ports = [PortMapping(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp)]
    spec.mounts = [
        .bind(source: "/host/data", target: "/data", readOnly: false),
        .volume(name: "app-vol", target: "/vol", readOnly: true),
        .tmpfs(target: "/tmp/scratch"),
    ]
    spec.networks = ["demo_default"]
    spec.platform = "linux/arm64"
    spec.rosetta = true
    spec.useInit = true
    spec.labels = ["capsule.project": "demo", "capsule.service": "web"]
    spec.dns = DNSConfiguration(
        nameservers: ["1.1.1.1"],
        searchDomains: ["demo.internal"],
        options: ["ndots:1"],
        domain: "demo.internal"
    )
    spec.readOnly = true
    spec.shmSize = "128m"

    let encoded = try JSONEncoder().encode(spec)
    let decoded = try JSONDecoder().decode(RunSpec.self, from: encoded)

    #expect(decoded == spec)
}

@Test func runSpecHashableEquality() {
    let a = RunSpec(image: "docker.io/library/nginx:latest")
    var b = RunSpec(image: "docker.io/library/nginx:latest")
    #expect(a == b)
    #expect(Set([a, b]).count == 1)

    b.name = "web"
    #expect(a != b)
    #expect(Set([a, b]).count == 2)
}

@Test func portMappingDecodesObservedJSONShape() throws {
    let json = Data("""
    { "containerPort": 80, "count": 1, "hostAddress": "0.0.0.0", "hostPort": 8099, "proto": "tcp" }
    """.utf8)
    let mapping = try JSONDecoder().decode(PortMapping.self, from: json)
    #expect(mapping == PortMapping(hostAddress: "0.0.0.0", hostPort: 8099, containerPort: 80, proto: .tcp, count: 1))
}

@Test func mountCodableRoundTripsAllCases() throws {
    let mounts: [Mount] = [
        .bind(source: "/host", target: "/container", readOnly: false),
        .volume(name: "vol", target: "/vol", readOnly: true),
        .tmpfs(target: "/tmp"),
    ]
    for mount in mounts {
        let encoded = try JSONEncoder().encode(mount)
        let decoded = try JSONDecoder().decode(Mount.self, from: encoded)
        #expect(decoded == mount)
    }
}
