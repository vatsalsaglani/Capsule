import AppCore
import Diagnostics
import RuntimeInstaller
import SwiftUI

/// Shown in place of the whole app shell when the `container` runtime can't
/// be found (P1D). Explains what's missing and offers to download the
/// signed installer package. The runtime-installation flow **never** runs it:
/// its only actions are "download" and "reveal/open", and the user runs the
/// installer themselves in Finder/Installer.app (rule 7, AGENTS.md).
struct OnboardingView: View {
    let model: RuntimeInstallerModel
    let onRuntimeAvailable: @MainActor () async -> Void
    @Environment(CapsuleCLIInstallStore.self) private var cliInstallStore
    @Environment(DiagnosticsStore.self) private var diagnostics

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Container Runtime Not Found")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Capsule manages containers through Apple's `container` command-line "
                            + "runtime, and it isn't installed (or Capsule couldn't find it)."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                }

                RuntimeDiagnosticChecksView(
                    store: diagnostics,
                    onRefresh: { Task { await runChecks() } },
                    onAction: handleDiagnosticAction
                )
                .frame(maxWidth: 560)

                downloadSection

                // Honest runtime-installation copy (rules 7 and 10, AGENTS.md).
                Text("Capsule never installs the Apple container runtime for you—it only downloads its installer and hands it off. You run it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                CommandLineToolSection(store: cliInstallStore)
                    .frame(maxWidth: 560)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(CapsuleMotion.standard, value: phaseKey)
        .task {
            cliInstallStore.refresh()
            await runChecks()
        }
    }

    private func runChecks() async {
        async let installProbe: Void = model.refresh()
        async let doctorProbe: Void = diagnostics.refresh()
        _ = await (installProbe, doctorProbe)
        if case .present = model.runtimePresence {
            await onRuntimeAvailable()
        }
    }

    private func handleDiagnosticAction(_ action: DiagnosticRemediationAction) {
        switch action {
        case .installRuntime:
            Task { await model.prepareInstaller() }
        case .updateRuntime(let releasePage):
            NSWorkspace.shared.open(releasePage)
        case .retry:
            Task { await runChecks() }
        case .startRuntime:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("container system start", forType: .string)
        }
    }

    @ViewBuilder
    private var downloadSection: some View {
        switch model.downloadPhase {
        case .idle:
            Button("Download Latest Runtime") {
                Task { await model.prepareInstaller() }
            }
            .keyboardShortcut(.defaultAction)

        case .resolving:
            ProgressView("Checking the latest release…")

        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction) {
                    Text("Downloading…")
                }
                .frame(maxWidth: 280)
            } else {
                ProgressView("Downloading…")
            }

        case .ready(let localURL, let humanInstructions):
            VStack(spacing: 12) {
                Text(humanInstructions)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button(localURL.isFileURL ? "Reveal in Finder" : "Open Release Page") {
                        reveal(localURL)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Check Again") {
                        Task {
                            model.resetDownloadPhase()
                            await model.refresh()
                        }
                    }
                }
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") {
                    Task { await model.prepareInstaller() }
                }
            }
        }
    }

    /// File URL → reveal the download in Finder; web URL (the no-`.pkg`
    /// fallback) → open it in the default browser. Never anything that
    /// executes the installer (rule 7).
    private func reveal(_ url: URL) {
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Drives the `.animation(value:)` above — a `String` is enough to
    /// distinguish the handful of `downloadPhase` cases without needing
    /// `RuntimeInstallDownloadPhase` itself to be `Hashable`.
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
