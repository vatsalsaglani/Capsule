import RuntimeInstaller
import SwiftUI

/// Shown in place of the whole app shell when the `container` runtime can't
/// be found (P1D). Explains what's missing and offers to download the
/// signed installer package — **never** runs it. Rule 7 (AGENTS.md) is
/// absolute: this view's only actions are "download" and "reveal/open"; the
/// user runs the installer themselves in Finder/Installer.app.
struct OnboardingView: View {
    let model: RuntimeInstallerModel

    var body: some View {
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

            searchedPathsNote

            downloadSection

            // Honest, load-bearing copy (rule 7 + rule 10, AGENTS.md) — never
            // implies Capsule installs anything on the user's behalf.
            Text("Capsule never installs anything for you — it only downloads the installer and hands it off. You run it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(CapsuleMotion.standard, value: phaseKey)
        .task { await model.refresh() }
    }

    private var searchedPathsNote: some View {
        Group {
            if case .missing(let searchedPaths) = model.runtimePresence, !searchedPaths.isEmpty {
                Text("Searched: \(searchedPaths.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
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
