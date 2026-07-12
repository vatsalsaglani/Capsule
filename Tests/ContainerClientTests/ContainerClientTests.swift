import Foundation
import Testing
@testable import ContainerClient

@Test func subprocessCapturesStdout() async throws {
    let result = try await Subprocess.run(executablePath: "/bin/echo", arguments: ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.stdoutText == "hello\n")
    #expect(result.stderr.isEmpty)
}

@Test func subprocessCapturesStderrAndExitCode() async throws {
    // /bin/sh is the executable under test here, invoked with an argv array —
    // production code never routes through a shell (plan §2.2).
    let result = try await Subprocess.run(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo oops 1>&2; exit 3"]
    )
    #expect(result.exitCode == 3)
    #expect(result.stderrText == "oops\n")
}

@Test func subprocessTimesOutAndTerminates() async throws {
    await #expect(throws: SubprocessError.self) {
        _ = try await Subprocess.run(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(200)
        )
    }
}

@Test func subprocessRejectsMissingExecutable() async throws {
    await #expect(throws: SubprocessError.self) {
        _ = try await Subprocess.run(executablePath: "/no/such/binary", arguments: [])
    }
}

@Test func semanticVersionParsesRealVersionLine() {
    let line = "container CLI version 1.1.0 (build: release, commit: 5973b9c)"
    #expect(SemanticVersion(firstIn: line) == SemanticVersion(major: 1, minor: 1, patch: 0))
    #expect(SemanticVersion(firstIn: "no version here") == nil)
}

@Test func semanticVersionOrdering() {
    #expect(SemanticVersion(major: 1, minor: 2, patch: 0) > SemanticVersion(major: 1, minor: 1, patch: 9))
    #expect(SemanticVersion(major: 2, minor: 0, patch: 0) > SemanticVersion(major: 1, minor: 99, patch: 99))
}

// Verbatim `container list --all --format json` capture, two containers
// (spike S2, 2026-07-13 — see docs/learnings/2026-07-12-runtime-cli-observations.md
// finding #3). The second container's config is documented there as
// "identical shape" to the first, differing only in id/labels/publishedPorts
// — reproduced in full here (not truncated) since a decode test needs valid
// JSON, but every field value for the second container beyond those three is
// copied verbatim from the first, per that note's explicit claim of identical
// shape.
private let s2TwoContainerListJSON = Data("""
[
  {
    "configuration": {
      "capAdd": [], "capDrop": [],
      "creationDate": "2026-07-12T20:25:15Z",
      "dns": { "nameservers": [], "options": [], "searchDomains": [] },
      "id": "s2-probe",
      "image": {
        "descriptor": { "digest": "sha256:ec4ed8...", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 10229 },
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
  },
  {
    "configuration": {
      "capAdd": [], "capDrop": [],
      "creationDate": "2026-07-12T20:25:15Z",
      "dns": { "nameservers": [], "options": [], "searchDomains": [] },
      "id": "s2-labeled",
      "image": {
        "descriptor": { "digest": "sha256:ec4ed8...", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 10229 },
        "reference": "docker.io/library/nginx:latest"
      },
      "labels": { "capsule.project": "demo", "capsule.service": "web" },
      "mounts": [],
      "networks": [
        { "network": "default", "options": { "hostname": "s2-labeled", "mtu": 1280 } }
      ],
      "platform": { "architecture": "arm64", "os": "linux" },
      "publishedPorts": [],
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
    "id": "s2-labeled",
    "status": {
      "networks": [
        {
          "hostname": "s2-labeled",
          "ipv4Address": "192.168.64.7/24",
          "ipv4Gateway": "192.168.64.1",
          "ipv6Address": "fd2e:2a8d:ce3a:268b:f03b:a4ff:fe79:435f/64",
          "macAddress": "f2:3b:a4:79:43:5f",
          "mtu": 1280,
          "network": "default",
          "variant": "reserved"
        }
      ],
      "startedDate": "2026-07-12T20:25:17Z",
      "state": "running"
    }
  }
]
""".utf8)

@Test func containerSummaryDecodesObservedJSONShape() throws {
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: s2TwoContainerListJSON)
    #expect(summaries.count == 2)

    let probe = summaries[0]
    #expect(probe.id == "s2-probe")
    #expect(probe.status == "running")
    #expect(probe.runState == .running)
    #expect(probe.imageReference == "docker.io/library/nginx:latest")
    #expect(probe.addresses == ["192.168.64.6"])
    #expect(probe.ports == [PortMapping(hostAddress: "0.0.0.0", hostPort: 8099, containerPort: 80, proto: .tcp, count: 1)])
    #expect(probe.labels.isEmpty)

    let labeled = summaries[1]
    #expect(labeled.id == "s2-labeled")
    #expect(labeled.labels["capsule.project"] == "demo")
    #expect(labeled.labels["capsule.service"] == "web")
    #expect(labeled.ports.isEmpty)
}

@Test func containerSummaryThrowsOnMissingStatusState() throws {
    // `status` present but without `.state` — structural drift must surface
    // loudly, not fall back to "unknown" silently (spike S2 tightening
    // list item #6).
    let json = Data("""
    [{ "id": "no-state", "configuration": { "id": "no-state" }, "status": {} }]
    """.utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode([ContainerSummary].self, from: json)
    }
}

@Test func containerSummaryThrowsOnMissingID() throws {
    let json = Data("""
    [{ "configuration": { "id": "x" }, "status": { "state": "running" } }]
    """.utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode([ContainerSummary].self, from: json)
    }
}
