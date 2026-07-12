import Foundation
import Testing
@testable import ContainerClient

@Test func createArgumentsMinimalSpecIsJustTheImage() {
    let spec = RunSpec(image: "docker.io/library/nginx:latest")
    #expect(spec.createArguments == ["docker.io/library/nginx:latest"])
}

@Test func createArgumentsFullSpecIsByteForByteDeterministic() {
    var spec = RunSpec(image: "docker.io/library/nginx:latest")
    spec.name = "web"
    spec.entrypoint = "/bin/sh"
    spec.environment = ["ZEBRA": "z", "ALPHA": "a", "MID": "m"]
    spec.workingDirectory = "/app"
    spec.user = "www-data"
    spec.ports = [
        PortMapping(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp),
        PortMapping(hostPort: 53, containerPort: 53, proto: .udp),
    ]
    spec.mounts = [
        .bind(source: "/host/data", target: "/data", readOnly: false),
        .bind(source: "/host/ro", target: "/ro", readOnly: true),
        .volume(name: "app-vol", target: "/vol", readOnly: false),
        .volume(name: "app-vol-ro", target: "/vol-ro", readOnly: true),
        .tmpfs(target: "/tmp/scratch"),
    ]
    spec.networks = ["demo_default", "demo_backend"]
    spec.platform = "linux/arm64"
    spec.rosetta = true
    spec.useInit = true
    spec.labels = ["capsule.service": "web", "capsule.project": "demo"]
    spec.dns = DNSConfiguration(
        nameservers: ["1.1.1.1", "8.8.8.8"],
        searchDomains: ["demo.internal"],
        options: ["ndots:1"],
        domain: "demo.internal"
    )
    spec.readOnly = true
    spec.shmSize = "128m"
    spec.command = ["nginx", "-g", "daemon off;"]

    #expect(spec.createArguments == [
        "--name", "web",
        "--entrypoint", "/bin/sh",
        "-e", "ALPHA=a",
        "-e", "MID=m",
        "-e", "ZEBRA=z",
        "-w", "/app",
        "-u", "www-data",
        "-p", "127.0.0.1:8080:80/tcp",
        "-p", "53:53/udp",
        "-v", "/host/data:/data",
        "-v", "/host/ro:/ro:ro",
        "-v", "app-vol:/vol",
        "-v", "app-vol-ro:/vol-ro:ro",
        "--tmpfs", "/tmp/scratch",
        "--network", "demo_default",
        "--network", "demo_backend",
        "--platform", "linux/arm64",
        "--rosetta",
        "--init",
        "-l", "capsule.project=demo",
        "-l", "capsule.service=web",
        "--dns", "1.1.1.1",
        "--dns", "8.8.8.8",
        "--dns-search", "demo.internal",
        "--dns-option", "ndots:1",
        "--dns-domain", "demo.internal",
        "--read-only",
        "--shm-size", "128m",
        "docker.io/library/nginx:latest",
        "nginx", "-g", "daemon off;",
    ])
}

@Test func createArgumentsEnvironmentAndLabelsAreOrderIndependent() {
    var specA = RunSpec(image: "nginx:latest")
    specA.environment = ["ZEBRA": "z", "ALPHA": "a"]
    specA.labels = ["capsule.service": "web", "capsule.project": "demo"]

    var specB = RunSpec(image: "nginx:latest")
    specB.environment = ["ALPHA": "a", "ZEBRA": "z"]
    specB.labels = ["capsule.project": "demo", "capsule.service": "web"]

    #expect(specA.createArguments == specB.createArguments)
}

@Test func createArgumentsBindMountReadOnlyVariants() {
    var rw = RunSpec(image: "nginx:latest")
    rw.mounts = [.bind(source: "/host", target: "/container", readOnly: false)]
    #expect(rw.createArguments == ["-v", "/host:/container", "nginx:latest"])

    var ro = RunSpec(image: "nginx:latest")
    ro.mounts = [.bind(source: "/host", target: "/container", readOnly: true)]
    #expect(ro.createArguments == ["-v", "/host:/container:ro", "nginx:latest"])
}

@Test func createArgumentsVolumeMountReadOnlyVariants() {
    var rw = RunSpec(image: "nginx:latest")
    rw.mounts = [.volume(name: "vol", target: "/data", readOnly: false)]
    #expect(rw.createArguments == ["-v", "vol:/data", "nginx:latest"])

    var ro = RunSpec(image: "nginx:latest")
    ro.mounts = [.volume(name: "vol", target: "/data", readOnly: true)]
    #expect(ro.createArguments == ["-v", "vol:/data:ro", "nginx:latest"])
}

@Test func createArgumentsTmpfsMount() {
    var spec = RunSpec(image: "nginx:latest")
    spec.mounts = [.tmpfs(target: "/tmp/x")]
    #expect(spec.createArguments == ["--tmpfs", "/tmp/x", "nginx:latest"])
}

@Test func createArgumentsPortVariantsIncludingUDPAndHostAddress() {
    var spec = RunSpec(image: "nginx:latest")
    spec.ports = [
        PortMapping(hostPort: 8080, containerPort: 80),
        PortMapping(hostAddress: "0.0.0.0", hostPort: 53, containerPort: 53, proto: .udp),
        PortMapping(hostAddress: "127.0.0.1", hostPort: 9090, containerPort: 9090, proto: .tcp),
    ]
    #expect(spec.createArguments == [
        "-p", "8080:80/tcp",
        "-p", "0.0.0.0:53:53/udp",
        "-p", "127.0.0.1:9090:9090/tcp",
        "nginx:latest",
    ])
}

@Test func createArgumentsRepeatedNetworksPreserveOrder() {
    var spec = RunSpec(image: "nginx:latest")
    spec.networks = ["net-a", "net-b", "net-c"]
    #expect(spec.createArguments == [
        "--network", "net-a",
        "--network", "net-b",
        "--network", "net-c",
        "nginx:latest",
    ])
}

@Test func createArgumentsDNSBlock() {
    var spec = RunSpec(image: "nginx:latest")
    spec.dns = DNSConfiguration(
        nameservers: ["1.1.1.1"],
        searchDomains: ["a.internal", "b.internal"],
        options: ["ndots:1", "timeout:2"],
        domain: "a.internal"
    )
    #expect(spec.createArguments == [
        "--dns", "1.1.1.1",
        "--dns-search", "a.internal",
        "--dns-search", "b.internal",
        "--dns-option", "ndots:1",
        "--dns-option", "timeout:2",
        "--dns-domain", "a.internal",
        "nginx:latest",
    ])
}

@Test func createArgumentsDNSWithoutDomainOmitsDNSDomainFlag() {
    var spec = RunSpec(image: "nginx:latest")
    spec.dns = DNSConfiguration(nameservers: ["1.1.1.1"])
    #expect(spec.createArguments == ["--dns", "1.1.1.1", "nginx:latest"])
}

@Test func createArgumentsBooleanFlagsOnlyAppearWhenTrue() {
    var allFalse = RunSpec(image: "nginx:latest")
    allFalse.rosetta = false
    allFalse.useInit = false
    allFalse.readOnly = false
    #expect(allFalse.createArguments == ["nginx:latest"])

    var allTrue = RunSpec(image: "nginx:latest")
    allTrue.rosetta = true
    allTrue.useInit = true
    allTrue.readOnly = true
    #expect(allTrue.createArguments == ["--rosetta", "--init", "--read-only", "nginx:latest"])
}

@Test func createArgumentsCommandTrailsAfterImage() {
    var spec = RunSpec(image: "nginx:latest")
    spec.command = ["nginx", "-g", "daemon off;"]
    #expect(spec.createArguments == ["nginx:latest", "nginx", "-g", "daemon off;"])
}
