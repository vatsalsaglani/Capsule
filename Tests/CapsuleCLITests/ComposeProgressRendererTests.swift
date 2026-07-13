import ComposePlanner
import ComposeRuntime
import ContainerClient
import Foundation
import Testing
@testable import CapsuleCLI

private func imageStep(_ service: String) -> PlanStep {
    .ensureImage(service: service, image: "\(service):latest", platform: nil)
}

@Test(arguments: [
    ([:], true, true),
    ([:], false, false),
    (["TERM": "dumb"], true, false),
    (["CI": "true"], true, false),
    (["CI": "0"], true, true),
    (["NO_COLOR": "1"], true, false),
    (["NO_COLOR": ""], true, true),
    (["CLICOLOR": "0"], true, false),
])
func composeProgressCapabilityDetectionMatrix(
    environment: [String: String],
    tty: Bool,
    expected: Bool
) {
    #expect(ComposeProgressCapabilities.detect(environment: environment, stdoutIsTTY: tty).isInteractive == expected)
}

@Test func composeProgressPlainModeIsBoundedAndControlFree() {
    var output = ""
    var renderer = ComposeProgressRenderer(
        capabilities: .init(isInteractive: false),
        write: { output += $0 }
    )
    let step = imageStep("redis")
    renderer.consume(.stepStarted(step))
    for percent in 0...29 {
        renderer.consume(.stepOutput(
            step: step,
            message: "[1/2] Fetching image \(percent)% (4 of 44 blobs, 65 MB/944.7 MB, 4.7 MB/s) [\(percent)s]"
        ))
    }
    renderer.consume(.stepOutput(step: step, message: "\u{001B}[31mregistry\rerror\u{001B}[0m"))
    renderer.consume(.stepOutput(step: step, message: "another unparsed tick"))
    renderer.consume(.stepCompleted(step))
    renderer.finish()

    #expect(output.contains("IMAGE [redis] START"))
    #expect(output.contains("fetching image 0%"))
    #expect(output.contains("fetching image 10%"))
    #expect(output.contains("fetching image 20%"))
    #expect(!output.contains("fetching image 11%"))
    #expect(output.components(separatedBy: "registry error").count == 2)
    #expect(output.contains("SUCCESS IMAGE [redis]"))
    #expect(!output.contains("\u{001B}"))
    #expect(!output.contains("\r"))
}

@Test func composeProgressServiceColorsAreStableAndReserveStateColors() {
    let first = ComposeProgressRenderer.colorCode(for: "redis")
    #expect(first == ComposeProgressRenderer.colorCode(for: "redis"))
    #expect(first != 31)
    #expect(first != 32)
    #expect(ComposeProgressRenderer.colorCode(for: "mysql") != 31)
    #expect(ComposeProgressRenderer.colorCode(for: "mysql") != 32)
}

@Test func composeProgressInteractiveRowsAreStableSortedAndServiceLabeled() {
    var output = ""
    var now: UInt64 = 1_000_000_000
    var renderer = ComposeProgressRenderer(
        capabilities: .init(isInteractive: true),
        write: { output += $0 },
        terminalSize: { .init(columns: 120, rows: 24) },
        nowNanoseconds: { now }
    )
    let services = ["redis-ui", "mysql", "redis", "localstack", "mysql-ui"]
    for service in services { renderer.consume(.stepStarted(imageStep(service))) }
    now += 200_000_000
    for (index, service) in services.enumerated() {
        renderer.consume(.stepOutput(
            step: imageStep(service),
            message: "[1/2] Fetching image \(index * 10)% (3 of 10 blobs, 10 MB/100 MB, 2 MB/s) [4s]"
        ))
        now += 200_000_000
    }

    let sanitized = output.replacingOccurrences(
        of: "\u{001B}\\[[0-9;]*[A-Za-z]",
        with: "",
        options: .regularExpression
    )
    for service in services { #expect(sanitized.contains(service)) }
    let tail = sanitized.split(separator: "\n").suffix(5).joined(separator: "\n")
    #expect(tail.range(of: "localstack")!.lowerBound < tail.range(of: "mysql")!.lowerBound)
    #expect(tail.range(of: "mysql")!.lowerBound < tail.range(of: "mysql-ui")!.lowerBound)
    #expect(tail.range(of: "mysql-ui")!.lowerBound < tail.range(of: "redis")!.lowerBound)
    #expect(tail.range(of: "redis")!.lowerBound < tail.range(of: "redis-ui")!.lowerBound)
}

@Test func composeProgressResponsiveRowsRetainIdentityPhaseAndPercent() {
    for width in [40, 80, 120] {
        var output = ""
        var renderer = ComposeProgressRenderer(
            capabilities: .init(isInteractive: true),
            write: { output += $0 },
            terminalSize: { .init(columns: width, rows: 24) },
            nowNanoseconds: { 1_000_000_000 }
        )
        let step = imageStep("redis")
        renderer.consume(.stepStarted(step))
        renderer.consume(.stepOutput(
            step: step,
            message: "[1/2] Fetching image 61% (27 of 44 blobs, 65 MB/944.7 MB, 4.7 MB/s) [11s]"
        ))
        let plain = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        #expect(plain.contains("redis"))
        #expect(plain.contains("fetching image"))
        #expect(plain.contains("61%"))
        if width == 40 {
            #expect(!plain.contains("4.7 MB/s"))
        } else if width == 120 {
            #expect(plain.contains("944.7 MB"))
            #expect(plain.contains("4.7 MB/s"))
        }
    }
}

@Test func composeProgressTerminalResizeAndHeightOverflowAreSafe() {
    var output = ""
    var size = ComposeTerminalSize(columns: 120, rows: 4)
    var now: UInt64 = 1_000_000_000
    var renderer = ComposeProgressRenderer(
        capabilities: .init(isInteractive: true),
        write: { output += $0 },
        terminalSize: { size },
        nowNanoseconds: { now }
    )
    for service in ["a", "b", "c", "d"] { renderer.consume(.stepStarted(imageStep(service))) }
    #expect(output.contains("switching to plain output"))
    let marker = try! #require(output.range(of: "PROGRESS terminal height exceeded"))
    let afterMarker = output[marker.lowerBound...]
    #expect(!afterMarker.contains("\u{001B}"))

    size = .init(columns: 40, rows: 24)
    now += 1_000_000_000
    renderer.consume(.stepOutput(step: imageStep("a"), message: "[1/2] Fetching image 20% [2s]"))
    #expect(output.contains("IMAGE [a] fetching image 20%"))
}

@Test func composeProgressCompletionFailureAndFinishClearDashboard() {
    var output = ""
    var renderer = ComposeProgressRenderer(
        capabilities: .init(isInteractive: true),
        write: { output += $0 },
        terminalSize: { .init(columns: 80, rows: 24) },
        nowNanoseconds: { 1_000_000_000 }
    )
    let redis = imageStep("redis")
    let mysql = imageStep("mysql")
    renderer.consume(.stepStarted(redis))
    renderer.consume(.stepCompleted(redis))
    renderer.consume(.stepFailed(mysql, message: "denied\r\u{001B}[31m!\u{001B}[0m")) // completion without start
    renderer.consume(.stepStarted(mysql))
    renderer.finish()

    #expect(output.contains("✓"))
    #expect(output.contains("✗"))
    #expect(output.contains("denied !"))
    #expect(output.contains("\u{001B}[1A\r\u{001B}[2K"))
    #expect(!output.hasSuffix("\u{001B}[?25h")) // renderer never hides the cursor
}

@Test func composeProgressFailurePreservesLatestUnknownDiagnostics() {
    for interactive in [false, true] {
        var output = ""
        var renderer = ComposeProgressRenderer(
            capabilities: .init(isInteractive: interactive),
            write: { output += $0 },
            terminalSize: { .init(columns: 120, rows: 24) },
            nowNanoseconds: { 1_000_000_000 }
        )
        let step = imageStep("registry")
        renderer.consume(.stepStarted(step))
        renderer.consume(.stepOutput(step: step, message: "[1/2] Fetching image 20% [2s]"))
        renderer.consume(.stepOutput(step: step, message: "Error: registry unreachable"))
        renderer.consume(.stepOutput(step: step, message: "retry detail: connection refused"))
        renderer.consume(.stepFailed(step, message: "no stderr output"))
        renderer.finish()

        #expect(output.contains("last diagnostic:"))
        #expect(output.contains("Error: registry unreachable"))
        #expect(output.contains("retry detail: connection refused"))
        if !interactive {
            #expect(output.components(separatedBy: "Error: registry unreachable").count == 3)
        }
    }
}

@Test func composeProgressRowsRespectTerminalCellsAndClearExactlyOncePerRow() {
    var output = ""
    var now: UInt64 = 1_000_000_000
    var renderer = ComposeProgressRenderer(
        capabilities: .init(isInteractive: true),
        write: { output += $0 },
        terminalSize: { .init(columns: 10, rows: 24) },
        nowNanoseconds: { now }
    )
    let step = imageStep("界e\u{0301}image")
    renderer.consume(.stepStarted(step))
    now += 200_000_000
    renderer.consume(.stepOutput(step: step, message: "[1/2] Fetching image 61% [2s]"))
    renderer.finish()

    let plain = output
        .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\r", with: "")
    for line in plain.split(separator: "\n") {
        #expect(ComposeProgressRenderer.visibleCellWidth(String(line)) <= 10)
    }
    #expect(ComposeProgressRenderer.visibleCellWidth("界") == 2)
    #expect(ComposeProgressRenderer.visibleCellWidth("e\u{0301}") == 1)
    #expect(ComposeProgressRenderer.visibleCellWidth(
        ComposeProgressRenderer.truncateToCells("界界界", maxCells: 5)
    ) <= 5)
    #expect(output.components(separatedBy: "\u{001B}[1A\r\u{001B}[2K").count - 1 == 2)
}

@Test func composeProgressColorsOnlyTheTypedServiceSegment() {
    let buildSpec = ImageBuildSpec(
        contextDirectory: URL(fileURLWithPath: "/tmp/build"),
        tag: "build:latest"
    )
    let cases: [(PlanStep, String, String)] = [
        (imageStep("image"), "⇣ image", "image"),
        (.ensureBuild(service: "build", spec: buildSpec), "◆ build", "build"),
        (.start(service: "start", containerReference: "start-box"), "▶ start", "start"),
    ]

    for (step, kindPrefix, service) in cases {
        var output = ""
        var renderer = ComposeProgressRenderer(
            capabilities: .init(isInteractive: true),
            write: { output += $0 },
            terminalSize: { .init(columns: 100, rows: 24) },
            nowNanoseconds: { 1_000_000_000 }
        )
        renderer.consume(.stepStarted(step))
        let color = ComposeProgressRenderer.colorCode(for: service)
        #expect(output.contains("\(kindPrefix) \u{001B}[\(color)m\(service)\u{001B}[0m"))
        #expect(!output.hasPrefix("\u{001B}"))
        renderer.finish()
    }
}

@Test func composeProgressSanitizerTerminatesStringControlsAndStripsC1() {
    #expect(ComposeProgressRenderer.sanitize(
        "before \u{001B}]title\u{0007} after"
    ) == "before after")
    #expect(ComposeProgressRenderer.sanitize(
        "before \u{001B}]title\u{001B}\\ after"
    ) == "before after")
    #expect(ComposeProgressRenderer.sanitize(
        "before \u{001B}Ppayload\u{001B}\\ after"
    ) == "before after")
    #expect(ComposeProgressRenderer.sanitize(
        "before \u{009D}title\u{009C} after"
    ) == "before after")
    #expect(ComposeProgressRenderer.sanitize(
        "\u{009B}31mred\u{009C} after"
    ) == "red after")
}

private enum ComposeProgressTestError: Error { case failed }

@Test func composeProgressDrainQuietConsumesWithoutBytesAndThrowingStreamCleansUp() async {
    var quietOutput = ""
    let quietPair = AsyncThrowingStream<ComposeEvent, Error>.makeStream(of: ComposeEvent.self)
    quietPair.continuation.yield(.stepStarted(imageStep("redis")))
    quietPair.continuation.finish()
    try? await drainComposeEvents(
        quietPair.stream,
        quiet: true,
        renderer: ComposeProgressRenderer(capabilities: .init(isInteractive: true), write: { quietOutput += $0 })
    )
    #expect(quietOutput.isEmpty)

    var throwingOutput = ""
    let throwingPair = AsyncThrowingStream<ComposeEvent, Error>.makeStream(of: ComposeEvent.self)
    throwingPair.continuation.yield(.stepStarted(imageStep("mysql")))
    throwingPair.continuation.finish(throwing: ComposeProgressTestError.failed)
    await #expect(throws: ComposeProgressTestError.self) {
        try await drainComposeEvents(
            throwingPair.stream,
            quiet: false,
            renderer: ComposeProgressRenderer(
                capabilities: .init(isInteractive: true),
                write: { throwingOutput += $0 },
                terminalSize: { .init(columns: 80, rows: 24) }
            )
        )
    }
    #expect(throwingOutput.contains("\u{001B}[1A\r\u{001B}[2K"))
}
