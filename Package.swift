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
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // SwiftTerm is added when the terminal screen lands (M1) — TerminalKit
        // stays protocol-only until then.
    ],
    targets: [
        .target(name: "EventBus"),
        .target(name: "ContainerClient"),
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
        .target(name: "TerminalKit"),
        .executableTarget(name: "CapsuleCLI", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            "ContainerClient",
            "ComposeSpec",
            "ComposePlanner",
            "ComposeRuntime",
            "ProjectStore",
        ]),
        .testTarget(name: "ContainerClientTests", dependencies: ["ContainerClient", "ContainerClientTestSupport"]),
        .testTarget(name: "ComposeSpecTests", dependencies: ["ComposeSpec"]),
        .testTarget(name: "ComposePlannerTests", dependencies: ["ComposePlanner"]),
        .testTarget(name: "SupervisorTests", dependencies: ["Supervisor"]),
    ]
)
