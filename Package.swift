// swift-tools-version: 6.2
import PackageDescription

// CapsuleKit — all business logic lives here (plan §2.1).
// App/ and CLI targets are thin frontends; every feature must be drivable
// from a unit test against these modules.
let package = Package(
    name: "CapsuleKit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "capsule", targets: ["CapsuleCLI"]),
        .library(name: "ContainerClient", targets: ["ContainerClient"]),
        .library(name: "ContainerClientTestSupport", targets: ["ContainerClientTestSupport"]),
        .library(name: "ComposeSpec", targets: ["ComposeSpec"]),
        .library(name: "ComposePlanner", targets: ["ComposePlanner"]),
        .library(name: "ComposeRuntime", targets: ["ComposeRuntime"]),
        .library(name: "Supervisor", targets: ["Supervisor"]),
        .library(name: "ProjectStore", targets: ["ProjectStore"]),
        .library(name: "EventBus", targets: ["EventBus"]),
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "RuntimeInstaller", targets: ["RuntimeInstaller"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // SwiftTerm is App-only (App/project.yml), not a root-package
        // dependency: the terminal screen's PTY spawn is raw (S3 decision —
        // `PTYExecSession` owns the PTY directly), so no CapsuleKit target
        // ever imports SwiftTerm; only App/Capsule's SwiftUI view does.
    ],
    targets: [
        .target(name: "EventBus"),
        .target(name: "ContainerClient", dependencies: ["EventBus"]),
        .target(name: "ContainerClientTestSupport", dependencies: ["ContainerClient"]),
        .target(name: "ComposeSpec", dependencies: [
            .product(name: "Yams", package: "Yams"),
        ]),
        .target(name: "ComposePlanner", dependencies: ["ComposeSpec"]),
        .target(name: "ComposeRuntime", dependencies: [
            "ComposePlanner", "ContainerClient", "EventBus",
        ]),
        .target(name: "Supervisor", dependencies: ["ContainerClient"]),
        .target(name: "ProjectStore"),
        // ContainerClient dependency backs `ShellDetector`'s `container exec`
        // probes (plan §3/P1C). The raw-PTY `PTYExecSession` itself doesn't
        // go through `ContainerRuntime` (S3: it needs direct master-fd/pid
        // control for cooperative terminate) — only shell detection does.
        // SwiftTerm stays App-only (see App/project.yml); no UI import here.
        .target(name: "TerminalKit", dependencies: ["ContainerClient"]),
        // TerminalKit dependency backs `RuntimeSession.makeTerminalSessionManager()`
        // (P1C composition-root wiring, mirrors `makeDetailStore`/
        // `makeImagesStore`/`makeSystemStore`) — still no SwiftUI/SwiftTerm here.
        .target(name: "AppCore", dependencies: ["ContainerClient", "EventBus", "TerminalKit"]),
        // P1D: runtime install/update evaluation + download handoff (never
        // executes the installer, rule 7 AGENTS.md). No SwiftUI import here —
        // App/Capsule/Onboarding/ is the thin frontend over this module.
        .target(name: "RuntimeInstaller", dependencies: ["ContainerClient"]),
        .executableTarget(name: "CapsuleCLI", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            "ContainerClient",
            "ComposeSpec",
            "ComposePlanner",
            "ComposeRuntime",
            "ProjectStore",
        ]),
        .testTarget(name: "ContainerClientTests", dependencies: ["ContainerClient", "ContainerClientTestSupport", "EventBus"]),
        .testTarget(name: "ComposeSpecTests", dependencies: ["ComposeSpec"]),
        .testTarget(name: "ComposePlannerTests", dependencies: ["ComposePlanner"]),
        .testTarget(name: "SupervisorTests", dependencies: ["Supervisor"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ContainerClient", "ContainerClientTestSupport", "EventBus"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit", "ContainerClient", "ContainerClientTestSupport"]),
        .testTarget(name: "RuntimeInstallerTests", dependencies: ["RuntimeInstaller", "ContainerClient", "ContainerClientTestSupport"]),
    ]
)
