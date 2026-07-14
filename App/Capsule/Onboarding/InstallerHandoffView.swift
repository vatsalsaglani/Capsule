import SwiftUI

/// The explicit hand-off between Capsule's download-only runtime updater and
/// Apple's Installer. Keeping the steps visible next to the downloaded file
/// prevents "downloaded" from being mistaken for "installed" while
/// preserving the no-auto-install boundary in AGENTS.md rule 7.
struct InstallerHandoffView: View {
    let localURL: URL
    let humanInstructions: String
    var checkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                localURL.isFileURL ? "Download complete — installation is still required" : "Manual download required",
                systemImage: "shippingbox.and.arrow.backward"
            )
            .font(.callout.weight(.semibold))

            Text(humanInstructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                if localURL.isFileURL {
                    step(1, "Reveal the downloaded .pkg in Finder.")
                    step(2, "Double-click the .pkg and complete Apple's Installer prompts.")
                } else {
                    step(1, "Open the release page and download the signed .pkg.")
                    step(2, "Double-click the downloaded .pkg and complete Apple's Installer prompts.")
                }
                step(3, "Return to Capsule and choose Check Again.")
            }
            .font(.caption)

            HStack(spacing: 10) {
                Button(localURL.isFileURL ? "Reveal Package in Finder" : "Open Release Page") {
                    reveal(localURL)
                }
                .keyboardShortcut(.defaultAction)

                Button("Check Again", systemImage: "arrow.clockwise", action: checkAgain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CapsulePalette.surface, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(CapsulePalette.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(CapsulePalette.accent, in: .circle)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// File URL → reveal the package in Finder; web URL → open the release
    /// page. This deliberately never launches Installer.app itself.
    private func reveal(_ url: URL) {
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
