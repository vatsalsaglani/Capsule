import AppCore
import AppKit
import SwiftUI

/// Thin SwiftUI frontend over `CapsuleCLIInstaller`. Filesystem inspection,
/// ownership rules, and mutations all remain in AppCore and are unit-tested.
struct CommandLineToolSection: View {
    let store: CapsuleCLIInstallStore

    @State private var isConfirmingReplacement = false
    @State private var replacementAction: CapsuleCLIInstallAction?
    @State private var copiedCommand = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Install a link at /usr/local/bin/capsule to use Capsule Compose, volumes, and networks from Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                phaseContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label("Command Line Tool", systemImage: "terminal")
                .font(.headline)
        }
        .confirmationDialog(
            "Update Capsule Command Link?",
            isPresented: $isConfirmingReplacement
        ) {
            Button("Update Link") {
                guard let replacementAction else { return }
                store.perform(replacementAction, confirmingReplacement: true)
                self.replacementAction = nil
            }
            Button("Cancel", role: .cancel) {
                replacementAction = nil
            }
        } message: {
            Text("Capsule will replace only the stale symlink it just inspected. Files, directories, and links owned by other tools are never overwritten.")
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .checking:
            ProgressView("Checking command link…")

        case .working:
            ProgressView("Updating command link…")

        case .ready(let status):
            statusContent(status)

        case .permissionRequired(let message, let manualCommand):
            statusLabel(
                "Terminal permission is required",
                systemImage: "lock.fill",
                color: Color(nsColor: .systemOrange)
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Capsule never runs sudo. Copy this command and review it in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manualCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button(copiedCommand ? "Copied" : "Copy Command", systemImage: copiedCommand ? "checkmark" : "doc.on.doc") {
                    copyToPasteboard(manualCommand)
                    copiedCommand = true
                }
                .accessibilityLabel(copiedCommand ? "Manual install command copied" : "Copy manual install command")
            }
            Button("Check Again") { store.refresh() }

        case .failed(let message):
            statusLabel(
                "Command link update failed",
                systemImage: "xmark.octagon.fill",
                color: Color(nsColor: .systemRed)
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Check Again") { store.refresh() }
        }
    }

    @ViewBuilder
    private func statusContent(_ status: CapsuleCLIInstallationStatus) -> some View {
        switch status {
        case .unavailable(let message):
            statusLabel(
                "Bundled command unavailable",
                systemImage: "xmark.octagon.fill",
                color: Color(nsColor: .systemRed)
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Check Again") { store.refresh() }

        case .notInstalled(let action):
            statusLabel(
                "Not installed in PATH",
                systemImage: "minus.circle",
                color: .secondary
            )
            Button("Add Capsule Command to PATH", systemImage: "plus") {
                store.perform(action)
            }
            .accessibilityHint("Creates /usr/local/bin/capsule as a symlink to the command bundled in this app")

        case .installed(let destination):
            statusLabel(
                "Available in Terminal",
                systemImage: "checkmark.circle.fill",
                color: Color(nsColor: .systemGreen)
            )
            Text(destination)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case .staleLink(let currentTarget, let isBroken, let action):
            statusLabel(
                isBroken ? "Installed link is broken" : "Installed link points to another Capsule app",
                systemImage: "exclamationmark.triangle.fill",
                color: Color(nsColor: .systemOrange)
            )
            Text("Current target: \(currentTarget)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Update Capsule Command Link…") {
                replacementAction = action
                isConfirmingReplacement = true
            }

        case .conflict(let message):
            statusLabel(
                "Command path is already in use",
                systemImage: "exclamationmark.octagon.fill",
                color: Color(nsColor: .systemRed)
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .accessibilityLabel("Command line tool status: \(title)")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
