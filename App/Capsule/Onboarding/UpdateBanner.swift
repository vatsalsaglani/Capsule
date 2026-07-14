import RuntimeInstaller
import SwiftUI

/// Dismissible "a newer runtime is available" banner (P1D) — same
/// download-and-hand-off flow as `OnboardingView`, just surfaced while the
/// app shell is otherwise usable (the runtime is present and working, just
/// not the latest release). Never auto-installs (rule 7, AGENTS.md); §6
/// rule 1: accent never encodes state, so this uses the neutral/orange
/// "heads up" treatment already established for the Containers/System
/// screens' transient-warning rows, not the accent color.
struct UpdateBanner: View {
    let model: RuntimeInstallerModel
    @Binding var isDismissed: Bool

    var body: some View {
        if !isDismissed, case .updateAvailable(let current, let latest) = model.updateStatus {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Label {
                        Text(verbatim: "Runtime update available: \(current) → \(latest)")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") {
                        isDismissed = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }

                actionRow
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .systemOrange).opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(CapsuleMotion.standard, value: phaseKey)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch model.downloadPhase {
        case .idle, .failed:
            Button("Download Update") {
                Task { await model.prepareInstaller() }
            }
            if case .failed(let message) = model.downloadPhase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .resolving:
            ProgressView("Checking…").controlSize(.small)
        case .downloading:
            ProgressView("Downloading…").controlSize(.small)
        case .ready(let localURL, let humanInstructions):
            InstallerHandoffView(
                localURL: localURL,
                humanInstructions: humanInstructions
            ) {
                Task {
                    model.resetDownloadPhase()
                    await model.refresh()
                }
            }
        }
    }

    private var phaseKey: String {
        switch model.downloadPhase {
        case .idle: "idle"
        case .resolving: "resolving"
        case .downloading: "downloading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
