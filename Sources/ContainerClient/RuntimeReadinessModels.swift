import Foundation

/// Runtime architecture identifier kept as a raw-value type so a future
/// Apple `container` release can report a new architecture without making
/// Capsule's persisted/XPC-facing model fail to decode.
public struct RuntimeArchitecture: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let arm64 = RuntimeArchitecture(rawValue: "arm64")
    public static let amd64 = RuntimeArchitecture(rawValue: "amd64")

    public static var current: RuntimeArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .amd64
        #else
        RuntimeArchitecture(rawValue: "unknown")
        #endif
    }
}

/// Read-only evidence that Apple's runtime has selected a default kernel for
/// the current architecture. "Configured" deliberately does not claim that
/// Capsule boot-tested the kernel; it mirrors the same managed default file
/// lookup Apple `container` 1.1 performs before creating a container.
public struct DefaultKernelReadiness: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case configured
        case notConfigured
    }

    public let architecture: RuntimeArchitecture
    public let state: State

    public init(architecture: RuntimeArchitecture, state: State) {
        self.architecture = architecture
        self.state = state
    }

    public static func configured(
        for architecture: RuntimeArchitecture = .current
    ) -> DefaultKernelReadiness {
        DefaultKernelReadiness(architecture: architecture, state: .configured)
    }

    public static func notConfigured(
        for architecture: RuntimeArchitecture = .current
    ) -> DefaultKernelReadiness {
        DefaultKernelReadiness(architecture: architecture, state: .notConfigured)
    }

    public var isConfigured: Bool { state == .configured }
}
