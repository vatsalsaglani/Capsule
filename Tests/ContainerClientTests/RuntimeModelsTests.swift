import Foundation
import Testing
@testable import ContainerClient

// MARK: - ContainerDetail

@Test func containerDetailDecodesObservedJSONShape() throws {
    // Verbatim `container list --all --format json` element (spike S2,
    // 2026-07-13) — `inspect` shares this exact schema (finding #7).
    let json = Data("""
    {
      "configuration": {
        "capAdd": [], "capDrop": [],
        "creationDate": "2026-07-12T20:25:15Z",
        "dns": { "nameservers": [], "options": [], "searchDomains": [] },
        "id": "s2-probe",
        "image": {
          "descriptor": { "digest": "sha256:ec4ed8b5299e", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 10229 },
          "reference": "docker.io/library/nginx:latest"
        },
        "labels": {},
        "mounts": [],
        "networks": [
          { "network": "default", "options": { "hostname": "s2-probe", "mtu": 1280 } }
        ],
        "platform": { "architecture": "arm64", "os": "linux" },
        "publishedPorts": [
          { "containerPort": 80, "count": 1, "hostAddress": "0.0.0.0", "hostPort": 8099, "proto": "tcp" }
        ],
        "publishedSockets": [],
        "readOnly": false,
        "resources": { "cpuOverhead": 1, "cpus": 4, "memoryInBytes": 1073741824 },
        "rosetta": false,
        "runtimeHandler": "container-runtime-linux",
        "ssh": false,
        "stopSignal": "SIGQUIT",
        "sysctls": {},
        "useInit": false,
        "virtualization": false
      },
      "id": "s2-probe",
      "status": {
        "networks": [
          {
            "hostname": "s2-probe",
            "ipv4Address": "192.168.64.6/24",
            "ipv4Gateway": "192.168.64.1",
            "ipv6Address": "fd2e:2a8d:ce3a:268b:f03b:a4ff:fe79:435e/64",
            "macAddress": "f2:3b:a4:79:43:5e",
            "mtu": 1280,
            "network": "default",
            "variant": "reserved"
          }
        ],
        "startedDate": "2026-07-12T20:25:17Z",
        "state": "running"
      }
    }
    """.utf8)

    let detail = try RuntimeJSON.makeDecoder().decode(ContainerDetail.self, from: json)
    #expect(detail.id == "s2-probe")
    #expect(detail.status == "running")
    #expect(detail.runState == .running)
    #expect(detail.imageReference == "docker.io/library/nginx:latest")
    #expect(detail.imageDigest == "sha256:ec4ed8b5299e")
    #expect(detail.labels.isEmpty)
    #expect(detail.ports == [PortMapping(hostAddress: "0.0.0.0", hostPort: 8099, containerPort: 80, proto: .tcp, count: 1)])
    #expect(detail.networks.count == 1)
    #expect(detail.networks[0].ipAddress == "192.168.64.6")
    #expect(detail.networks[0].ipv4Address == "192.168.64.6/24")
    #expect(detail.platform == Platform(architecture: "arm64", os: "linux"))
    #expect(detail.resources == Resources(cpus: 4, memoryInBytes: 1_073_741_824))
    #expect(detail.stopSignal == "SIGQUIT")
    #expect(detail.useInit == false)
    #expect(detail.readOnly == false)
    #expect(detail.startedAt != nil)
    #expect(detail.createdAt != nil)
    #expect(detail.mounts.isEmpty)
}

// MARK: - MountDetail / ContainerDetail.mounts

@Test func mountDetailDecodesBindVolumeAndTmpfsShapes() throws {
    // Populated `configuration.mounts[]` shape (verified live probe, P1A
    // implementation PR — corrects the Contract PR's "S2 only ever observed
    // an empty array" note). One bind rw, one bind ro, one volume rw, one
    // volume ro, one tmpfs — covers every `Kind` case and both read-only
    // states.
    let json = Data("""
    [
      {"destination":"/data","source":"/host/data","options":[],"type":{"virtiofs":{}}},
      {"destination":"/ro","source":"/host/ro","options":["ro"],"type":{"virtiofs":{}}},
      {"destination":"/vol","source":"/Users/x/volumes/app-vol/volume.img","options":[],"type":{"volume":{"name":"app-vol","format":"ext4","cache":"auto","sync":"full"}}},
      {"destination":"/vol-ro","source":"/Users/x/volumes/app-vol-ro/volume.img","options":["ro"],"type":{"volume":{"name":"app-vol-ro","format":"ext4","cache":"auto","sync":"full"}}},
      {"destination":"/tmp/scratch","source":"tmpfs","options":[],"type":{"tmpfs":{}}}
    ]
    """.utf8)

    let mounts = try RuntimeJSON.makeDecoder().decode([MountDetail].self, from: json)
    #expect(mounts.count == 5)

    #expect(mounts[0].destination == "/data")
    #expect(mounts[0].source == "/host/data")
    #expect(mounts[0].kind == .bind)
    #expect(mounts[0].isReadOnly == false)

    #expect(mounts[1].destination == "/ro")
    #expect(mounts[1].kind == .bind)
    #expect(mounts[1].isReadOnly == true)

    #expect(mounts[2].destination == "/vol")
    #expect(mounts[2].kind == .volume(name: "app-vol"))
    #expect(mounts[2].isReadOnly == false)

    #expect(mounts[3].destination == "/vol-ro")
    #expect(mounts[3].kind == .volume(name: "app-vol-ro"))
    #expect(mounts[3].isReadOnly == true)

    #expect(mounts[4].destination == "/tmp/scratch")
    #expect(mounts[4].source == "tmpfs")
    #expect(mounts[4].kind == .tmpfs)
    #expect(mounts[4].isReadOnly == false)
}

@Test func mountDetailUnrecognizedTypeKeySurfacesAsUnknown() throws {
    let json = Data("""
    {"destination":"/weird","source":null,"options":[],"type":{"somethingNew":{}}}
    """.utf8)
    let mount = try RuntimeJSON.makeDecoder().decode(MountDetail.self, from: json)
    #expect(mount.kind == .unknown("somethingNew"))
}

@Test func containerDetailDecodesPopulatedMounts() throws {
    let json = Data("""
    {
      "configuration": {
        "id": "s2-probe",
        "mounts": [
          {"destination":"/data","source":"/host/data","options":[],"type":{"virtiofs":{}}},
          {"destination":"/vol-ro","source":"/Users/x/volumes/app-vol-ro/volume.img","options":["ro"],"type":{"volume":{"name":"app-vol-ro"}}}
        ]
      },
      "id": "s2-probe",
      "status": { "state": "running" }
    }
    """.utf8)

    let detail = try RuntimeJSON.makeDecoder().decode(ContainerDetail.self, from: json)
    #expect(detail.mounts.count == 2)
    #expect(detail.mounts[0].kind == .bind)
    #expect(detail.mounts[1].kind == .volume(name: "app-vol-ro"))
    #expect(detail.mounts[1].isReadOnly == true)
}

// MARK: - StatsSample

@Test func statsSampleDecodesObservedJSONShape() throws {
    // Verbatim `container stats --no-stream --format json s2-probe` capture.
    let json = Data("""
    [{"blockReadBytes":21536768,"blockWriteBytes":8192,"cpuUsageUsec":19568,"id":"s2-probe","memoryLimitBytes":1073741824,"memoryUsageBytes":27713536,"networkRxBytes":21834,"networkTxBytes":602,"numProcesses":6}]
    """.utf8)
    let samples = try RuntimeJSON.makeDecoder().decode([StatsSample].self, from: json)
    #expect(samples.count == 1)
    let sample = samples[0]
    #expect(sample.id == "s2-probe")
    #expect(sample.cpuUsageMicroseconds == 19568)
    #expect(sample.memoryUsageBytes == 27_713_536)
    #expect(sample.memoryLimitBytes == 1_073_741_824)
    #expect(sample.blockReadBytes == 21_536_768)
    #expect(sample.blockWriteBytes == 8192)
    #expect(sample.networkReceivedBytes == 21834)
    #expect(sample.networkSentBytes == 602)
    #expect(sample.processCount == 6)
}

// MARK: - SystemStatus / SystemDiskUsage

@Test func systemStatusDecodesObservedJSONShape() throws {
    // Verbatim `container system status --format json` capture.
    let json = Data("""
    {"apiServerAppName":"container-apiserver","apiServerBuild":"release","apiServerCommit":"5973b9cc626a3e7a499bb316a958237ebe14e2ed","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","appRoot":"/Users/x/Library/Application Support/com.apple.container/","installRoot":"/usr/local/","status":"running"}
    """.utf8)
    let status = try RuntimeJSON.makeDecoder().decode(SystemStatus.self, from: json)
    #expect(status.status == "running")
    #expect(status.isRunning == true)
    #expect(status.apiServerAppName == "container-apiserver")
    #expect(status.apiServerBuild == "release")
    #expect(status.apiServerCommit == "5973b9cc626a3e7a499bb316a958237ebe14e2ed")
    #expect(status.apiServerVersion == "container-apiserver version 1.1.0 (build: release, commit: 5973b9c)")
    #expect(status.installRoot == "/usr/local/")
}

@Test func systemDiskUsageDecodesObservedJSONShape() throws {
    // Verbatim `container system df --format json` capture.
    let json = Data("""
    {"containers":{"active":1,"reclaimable":0,"sizeInBytes":455069696,"total":1},"images":{"active":1,"reclaimable":323076096,"sizeInBytes":650096640,"total":3},"volumes":{"active":0,"reclaimable":69390336,"sizeInBytes":69390336,"total":1}}
    """.utf8)
    let usage = try RuntimeJSON.makeDecoder().decode(SystemDiskUsage.self, from: json)
    #expect(usage.containers == ResourceUsage(total: 1, active: 1, sizeInBytes: 455_069_696, reclaimableBytes: 0))
    #expect(usage.images == ResourceUsage(total: 3, active: 1, sizeInBytes: 650_096_640, reclaimableBytes: 323_076_096))
    #expect(usage.volumes == ResourceUsage(total: 1, active: 0, sizeInBytes: 69_390_336, reclaimableBytes: 69_390_336))
}

// MARK: - VolumeSummary

@Test func volumeSummaryDecodesObservedJSONShape() throws {
    // Verbatim `container volume ls --format json` capture (spike S2 §3).
    let json = Data("""
    [{"configuration":{"creationDate":"2026-07-12T20:25:40Z","driver":"local","format":"ext4","labels":{},"name":"s2-vol","options":{},"sizeInBytes":549755813888,"source":"/Users/x/volumes/s2-vol/volume.img"},"id":"s2-vol"}]
    """.utf8)
    let volumes = try RuntimeJSON.makeDecoder().decode([VolumeSummary].self, from: json)
    #expect(volumes.count == 1)
    let volume = volumes[0]
    #expect(volume.name == "s2-vol")
    #expect(volume.id == "s2-vol")
    #expect(volume.driver == "local")
    #expect(volume.format == "ext4")
    #expect(volume.sizeInBytes == 549_755_813_888)
    #expect(volume.source == "/Users/x/volumes/s2-vol/volume.img")
    #expect(volume.labels.isEmpty)
    #expect(volume.createdAt != nil)
}

// MARK: - NetworkSummary

@Test func networkSummaryDecodesObservedJSONShape() throws {
    // Verbatim `container network ls --format json` capture (spike S2 §4).
    let json = Data("""
    [{"configuration":{"creationDate":"2026-07-12T12:21:18Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd2e:2a8d:ce3a:268b::/64"}}]
    """.utf8)
    let networks = try RuntimeJSON.makeDecoder().decode([NetworkSummary].self, from: json)
    #expect(networks.count == 1)
    let network = networks[0]
    #expect(network.name == "default")
    #expect(network.id == "default")
    #expect(network.mode == "nat")
    #expect(network.plugin == "container-network-vmnet")
    #expect(network.labels["com.apple.container.resource.role"] == "builtin")
    #expect(network.status == NetworkStatus(
        ipv4Gateway: "192.168.64.1",
        ipv4Subnet: "192.168.64.0/24",
        ipv6Subnet: "fd2e:2a8d:ce3a:268b::/64"
    ))
}

// MARK: - ImageSummary

@Test func imageSummaryDecodesShapeFromFieldMappingBrief() throws {
    // NOTE: S2 did not capture a full verbatim `image list --format json`
    // payload (learnings finding #2/#8 only describe field *locations* —
    // top-level id/configuration/variants, configuration.name,
    // configuration.descriptor.digest, configuration.creationDate,
    // variants[].platform — not a full sample). This fixture follows those
    // documented locations; flagged as a documented gap in the P1A report
    // rather than presented as a verbatim capture.
    let json = Data("""
    [{
      "id": "sha256:28bd5fe8b56d",
      "configuration": {
        "name": "docker.io/library/alpine:latest",
        "creationDate": "2026-07-12T20:10:00Z",
        "descriptor": { "digest": "sha256:28bd5fe8b56d", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 1638 }
      },
      "variants": [
        { "platform": { "architecture": "arm64", "os": "linux" } }
      ]
    }]
    """.utf8)
    let images = try RuntimeJSON.makeDecoder().decode([ImageSummary].self, from: json)
    #expect(images.count == 1)
    let image = images[0]
    #expect(image.id == "sha256:28bd5fe8b56d")
    #expect(image.reference == "docker.io/library/alpine:latest")
    #expect(image.digest == "sha256:28bd5fe8b56d")
    #expect(image.createdAt != nil)
    #expect(image.platforms == [Platform(architecture: "arm64", os: "linux")])
}

// MARK: - strippingCIDRSuffix

@Test func strippingCIDRSuffixStripsSlashSuffix() {
    #expect(strippingCIDRSuffix("192.168.64.6/24") == "192.168.64.6")
    #expect(strippingCIDRSuffix("192.168.64.6") == "192.168.64.6")
}
