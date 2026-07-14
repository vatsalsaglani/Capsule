import AppCore
import Diagnostics
import SwiftUI

/// Shared native presentation for the one CapsuleKit diagnostics snapshot
/// used by onboarding and System. It never derives readiness or remediation;
/// the view only renders the engine's typed state.
struct RuntimeDiagnosticChecksView: View {
    let store: DiagnosticsStore
    var onRefresh: () -> Void
    var onAction: (DiagnosticRemediationAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Runtime Doctor")
                        .font(.headline)
                    Text(overallSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Checks", systemImage: "arrow.clockwise", action: onRefresh)
                    .disabled(store.isRefreshing)
            }

            ForEach(store.snapshot.checks) { check in
                diagnosticRow(check)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CapsulePalette.surface, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(CapsulePalette.hairline)
        }
        .animation(CapsuleMotion.standard, value: store.snapshot)
    }

    private func diagnosticRow(_ check: DiagnosticCheckSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(check.status)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.id.title)
                    .font(.callout.weight(.semibold))
                Text(check.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let remediation = check.remediation {
                Button(remediation.label) { onAction(remediation.action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(remediation.instruction)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.id.title), \(check.status.rawValue), \(check.summary)")
    }

    @ViewBuilder
    private func statusIcon(_ status: DiagnosticCheckStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Color(nsColor: .systemGray))
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Color(nsColor: .systemGray))
        }
    }

    private var overallSummary: String {
        switch store.snapshot.overall {
        case .running: "Checking the local runtime and Apple release metadata."
        case .ready: "Capsule is ready to use the Apple container runtime."
        case .needsAction: "The runtime is reachable, with items that need attention."
        case .failed: "Resolve the failed checks before using Capsule."
        }
    }
}
