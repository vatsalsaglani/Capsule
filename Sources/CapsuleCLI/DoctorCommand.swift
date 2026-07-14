import ArgumentParser
import Diagnostics

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the Apple container runtime installation."
    )

    @Flag(help: "Skip the GitHub latest-release check.")
    var offline = false

    func run() async throws {
        let diagnostics = RuntimeDiagnostics()
        var rendered: [DiagnosticCheckID: DiagnosticCheckSnapshot] = [:]
        var final: DiagnosticsSnapshot?

        for await snapshot in diagnostics.snapshots(for: offline ? .offline : .standard) {
            final = snapshot
            for check in snapshot.checks where check.status.isTerminal && rendered[check.id] != check {
                rendered[check.id] = check
                render(check)
            }
        }

        guard let final else { throw ExitCode(1) }
        switch final.overall {
        case .ready:
            print("\n✓ Capsule is ready to use the Apple container runtime")
        case .needsAction:
            print("\n⚠ Capsule can reach the runtime, but one or more checks need attention")
        case .failed:
            print("\n✗ Capsule cannot use the runtime until the failed checks are resolved")
            throw ExitCode(1)
        case .running:
            throw ExitCode(1)
        }
    }

    private func render(_ check: DiagnosticCheckSnapshot) {
        let icon = switch check.status {
        case .passed: "✓"
        case .warning: "⚠"
        case .failed: "✗"
        case .skipped: "–"
        case .pending, .running: "→"
        }
        print("\(icon) \(check.id.title): \(check.summary)")
        if let detail = check.detail, !detail.isEmpty {
            print("  \(detail)")
        }
        if let remediation = check.remediation {
            print("  \(remediation.instruction)")
        }
    }
}
