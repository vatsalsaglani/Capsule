import ContainerClient
import Foundation

public enum DiagnosticCheckID: String, Codable, Sendable, CaseIterable, Identifiable {
    case binary
    case version
    case runtimeStatus
    case defaultKernel
    case update

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .binary: "Container CLI"
        case .version: "Runtime Version"
        case .runtimeStatus: "Runtime Service"
        case .defaultKernel: "Default Kernel"
        case .update: "Runtime Update"
        }
    }
}

public enum DiagnosticCheckStatus: String, Codable, Sendable {
    case pending
    case running
    case passed
    case warning
    case failed
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: false
        case .passed, .warning, .failed, .skipped: true
        }
    }
}

public enum DiagnosticRemediationAction: Sendable, Equatable {
    case installRuntime(releasePage: URL)
    case startRuntime
    case configureDefaultKernel(command: String)
    case updateRuntime(releasePage: URL)
    case retry
}

public struct DiagnosticRemediation: Sendable, Equatable {
    public let label: String
    public let instruction: String
    public let action: DiagnosticRemediationAction

    public init(label: String, instruction: String, action: DiagnosticRemediationAction) {
        self.label = label
        self.instruction = instruction
        self.action = action
    }
}

public struct DiagnosticCheckSnapshot: Sendable, Equatable, Identifiable {
    public let id: DiagnosticCheckID
    public let status: DiagnosticCheckStatus
    public let summary: String
    /// Ephemeral, user-facing evidence. Reports are never written to incident
    /// history, so a located binary path can be useful here without leaking
    /// into a persisted diagnostic export.
    public let detail: String?
    public let remediation: DiagnosticRemediation?

    public init(
        id: DiagnosticCheckID,
        status: DiagnosticCheckStatus,
        summary: String,
        detail: String? = nil,
        remediation: DiagnosticRemediation? = nil
    ) {
        self.id = id
        self.status = status
        self.summary = summary
        self.detail = detail
        self.remediation = remediation
    }
}

public enum DiagnosticOverallStatus: String, Codable, Sendable {
    case running
    case ready
    case needsAction
    case failed
}

public struct DiagnosticsSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date?
    public let checks: [DiagnosticCheckSnapshot]
    public let overall: DiagnosticOverallStatus

    public init(
        id: UUID,
        startedAt: Date,
        completedAt: Date?,
        checks: [DiagnosticCheckSnapshot],
        overall: DiagnosticOverallStatus
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.checks = checks
        self.overall = overall
    }

    public static var idle: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            id: UUID(),
            startedAt: Date(),
            completedAt: nil,
            checks: DiagnosticCheckID.allCases.map {
                DiagnosticCheckSnapshot(id: $0, status: .pending, summary: "Waiting to run")
            },
            overall: .running
        )
    }
}

public struct DiagnosticsRequest: Sendable, Equatable {
    public enum UpdatePolicy: Sendable, Equatable {
        case check
        case skip
    }

    public var updatePolicy: UpdatePolicy

    public init(updatePolicy: UpdatePolicy = .check) {
        self.updatePolicy = updatePolicy
    }

    public static let standard = DiagnosticsRequest()
    public static let offline = DiagnosticsRequest(updatePolicy: .skip)
}

public protocol RuntimeDiagnosticsProviding: Sendable {
    func snapshots(for request: DiagnosticsRequest) -> AsyncStream<DiagnosticsSnapshot>
}

/// Shared doctor/onboarding state machine. A missing binary, incompatible
/// version, stopped runtime, and release-metadata failure are typed check
/// results rather than thrown control flow; cancellation simply stops the
/// stream. Frontends format immutable snapshots and own no readiness policy.
public struct RuntimeDiagnostics: RuntimeDiagnosticsProviding, Sendable {
    private let locateBinary: @Sendable () -> String?
    private let makeRuntime: @Sendable () throws -> any ContainerRuntime
    private let fetchLatestRelease: @Sendable () async throws -> GitHubRelease

    public init(repository: String = "apple/container") {
        let checker = RuntimeUpdateChecker(repository: repository)
        self.init(
            locateBinary: { ContainerBinaryLocator.locate() },
            makeRuntime: { try CLIProcessClient() },
            fetchLatestRelease: { try await checker.latestRelease() }
        )
    }

    public init(
        locateBinary: @escaping @Sendable () -> String?,
        makeRuntime: @escaping @Sendable () throws -> any ContainerRuntime,
        fetchLatestRelease: @escaping @Sendable () async throws -> GitHubRelease
    ) {
        self.locateBinary = locateBinary
        self.makeRuntime = makeRuntime
        self.fetchLatestRelease = fetchLatestRelease
    }

    public func snapshots(for request: DiagnosticsRequest = .standard) -> AsyncStream<DiagnosticsSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DiagnosticsSnapshot.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        let producer = Task {
            await produce(request: request, continuation: continuation)
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    private func produce(
        request: DiagnosticsRequest,
        continuation: AsyncStream<DiagnosticsSnapshot>.Continuation
    ) async {
        let runID = UUID()
        let startedAt = Date()
        var checks = DiagnosticCheckID.allCases.map {
            DiagnosticCheckSnapshot(id: $0, status: .pending, summary: "Waiting to run")
        }

        func snapshot(completedAt: Date? = nil) -> DiagnosticsSnapshot {
            DiagnosticsSnapshot(
                id: runID,
                startedAt: startedAt,
                completedAt: completedAt,
                checks: checks,
                overall: Self.overall(for: checks, completed: completedAt != nil)
            )
        }

        func replace(_ result: DiagnosticCheckSnapshot) {
            guard let index = checks.firstIndex(where: { $0.id == result.id }) else { return }
            checks[index] = result
            continuation.yield(snapshot())
        }

        continuation.yield(snapshot())
        replace(.init(id: .binary, status: .running, summary: "Looking for Apple's container CLI"))
        guard !Task.isCancelled else { continuation.finish(); return }

        guard let binaryPath = locateBinary() else {
            let releases = URL(string: "https://github.com/apple/container/releases")!
            replace(.init(
                id: .binary,
                status: .failed,
                summary: "Apple container CLI was not found",
                detail: "Searched $\(ContainerBinaryLocator.environmentOverrideKey), \(ContainerBinaryLocator.defaultInstallPath), and $PATH.",
                remediation: .init(
                    label: "Install Runtime",
                    instruction: "Download Apple's signed installer, run it yourself, then check again.",
                    action: .installRuntime(releasePage: releases)
                )
            ))
            for id in [DiagnosticCheckID.version, .runtimeStatus, .defaultKernel, .update] {
                replace(.init(id: id, status: .skipped, summary: "Skipped because the container CLI is unavailable"))
            }
            continuation.yield(snapshot(completedAt: Date()))
            continuation.finish()
            return
        }
        replace(.init(
            id: .binary,
            status: .passed,
            summary: "Apple container CLI is available",
            detail: binaryPath
        ))

        let runtime: any ContainerRuntime
        do {
            runtime = try makeRuntime()
        } catch {
            replace(.init(id: .version, status: .failed, summary: "The container CLI could not be opened"))
            replace(.init(id: .runtimeStatus, status: .skipped, summary: "Skipped because the runtime client is unavailable"))
            replace(.init(id: .defaultKernel, status: .skipped, summary: "Skipped because the runtime client is unavailable"))
            replace(.init(id: .update, status: .skipped, summary: "Skipped because the installed version is unavailable"))
            continuation.yield(snapshot(completedAt: Date()))
            continuation.finish()
            return
        }

        replace(.init(id: .version, status: .running, summary: "Reading the installed version"))
        var installedVersion: SemanticVersion?
        do {
            let version = try await runtime.cliVersion()
            installedVersion = version
            if version.major == 1 {
                replace(.init(
                    id: .version,
                    status: .passed,
                    summary: "Runtime version \(version) is supported",
                    detail: "Capsule targets Apple container 1.x."
                ))
            } else {
                replace(.init(
                    id: .version,
                    status: .failed,
                    summary: "Runtime version \(version) is unsupported",
                    detail: "Capsule currently supports Apple container 1.x only."
                ))
            }
        } catch {
            replace(.init(
                id: .version,
                status: .failed,
                summary: "The installed runtime version could not be read",
                remediation: .init(label: "Retry", instruction: "Check the runtime installation and run diagnostics again.", action: .retry)
            ))
        }
        guard !Task.isCancelled else { continuation.finish(); return }

        replace(.init(id: .runtimeStatus, status: .running, summary: "Checking the runtime service"))
        var runtimeIsRunning = false
        do {
            let status = try await runtime.systemStatus()
            if status.isRunning {
                runtimeIsRunning = true
                replace(.init(
                    id: .runtimeStatus,
                    status: .passed,
                    summary: "Runtime service is running",
                    detail: status.apiServerVersion.map { "API server \($0)" }
                ))
            } else {
                replace(.init(
                    id: .runtimeStatus,
                    status: .warning,
                    summary: "Runtime service is not running",
                    detail: "Current state: \(status.status)",
                    remediation: .init(
                        label: "Start Runtime",
                        instruction: "Run `container system start`, then check again.",
                        action: .startRuntime
                    )
                ))
            }
        } catch {
            replace(.init(
                id: .runtimeStatus,
                status: .warning,
                summary: "Runtime service status could not be queried",
                remediation: .init(
                    label: "Start Runtime",
                    instruction: "Run `container system start`, then check again.",
                    action: .startRuntime
                )
            ))
        }
        guard !Task.isCancelled else { continuation.finish(); return }

        if !runtimeIsRunning {
            replace(.init(
                id: .defaultKernel,
                status: .skipped,
                summary: "Skipped because the runtime service is unavailable"
            ))
        } else {
            replace(.init(id: .defaultKernel, status: .running, summary: "Checking the default kernel"))
            do {
                let readiness = try await runtime.defaultKernelReadiness()
                if readiness.isConfigured {
                    replace(.init(
                        id: .defaultKernel,
                        status: .passed,
                        summary: "Default \(readiness.architecture.rawValue) kernel is configured"
                    ))
                } else {
                    let command = "container system kernel set --recommended --arch \(readiness.architecture.rawValue)"
                    replace(.init(
                        id: .defaultKernel,
                        status: .failed,
                        summary: "Default \(readiness.architecture.rawValue) kernel is not configured",
                        detail: "Container creation is unavailable until Apple container has a default kernel for this architecture.",
                        remediation: .init(
                            label: "Copy Setup Command",
                            instruction: "Run `\(command)`, then check again.",
                            action: .configureDefaultKernel(command: command)
                        )
                    ))
                }
            } catch {
                replace(.init(
                    id: .defaultKernel,
                    status: .warning,
                    summary: "Default kernel readiness could not be checked",
                    detail: "The runtime service is running, but Capsule could not verify its default kernel selection.",
                    remediation: .init(
                        label: "Retry",
                        instruction: "Check the runtime installation and run diagnostics again.",
                        action: .retry
                    )
                ))
            }
        }
        guard !Task.isCancelled else { continuation.finish(); return }

        switch request.updatePolicy {
        case .skip:
            replace(.init(id: .update, status: .skipped, summary: "Online release check was skipped"))
        case .check:
            guard let installedVersion else {
                replace(.init(id: .update, status: .skipped, summary: "Skipped because the installed version is unavailable"))
                break
            }
            replace(.init(id: .update, status: .running, summary: "Checking Apple's latest release"))
            do {
                let release = try await fetchLatestRelease()
                if let latest = release.version, latest > installedVersion {
                    replace(.init(
                        id: .update,
                        status: .warning,
                        summary: "Runtime update available: \(installedVersion) → \(latest)",
                        detail: release.htmlURL.absoluteString,
                        remediation: .init(
                            label: "View Update",
                            instruction: "Review Apple's release and run the signed installer yourself.",
                            action: .updateRuntime(releasePage: release.htmlURL)
                        )
                    ))
                } else if release.version == nil {
                    replace(.init(
                        id: .update,
                        status: .warning,
                        summary: "The latest release tag could not be interpreted",
                        detail: release.tagName
                    ))
                } else {
                    replace(.init(id: .update, status: .passed, summary: "Runtime is current with Apple's latest release"))
                }
            } catch {
                replace(.init(
                    id: .update,
                    status: .warning,
                    summary: "Apple's release metadata could not be reached",
                    detail: "The installed runtime checks are still valid. Retry online later.",
                    remediation: .init(label: "Retry", instruction: "Run diagnostics again when online.", action: .retry)
                ))
            }
        }

        guard !Task.isCancelled else { continuation.finish(); return }
        continuation.yield(snapshot(completedAt: Date()))
        continuation.finish()
    }

    private static func overall(
        for checks: [DiagnosticCheckSnapshot],
        completed: Bool
    ) -> DiagnosticOverallStatus {
        guard completed else { return .running }
        if checks.contains(where: {
            ($0.id == .binary || $0.id == .version || $0.id == .defaultKernel) && $0.status == .failed
        }) {
            return .failed
        }
        if checks.contains(where: { $0.status == .warning || $0.status == .failed }) {
            return .needsAction
        }
        return .ready
    }
}
