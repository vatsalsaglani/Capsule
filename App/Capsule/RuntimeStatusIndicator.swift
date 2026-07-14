import SwiftUI

/// One visual vocabulary for the Apple container service's app-level
/// availability. This is intentionally separate from container lifecycle
/// colors: an unavailable runtime is a blocking error (red), while an
/// individual stopped container is a normal state (gray).
struct RuntimeStatusIndicator: View {
    enum Status {
        case checking
        case running
        case unavailable
    }

    let status: Status
    var showsLabel = true

    private var color: Color {
        switch status {
        case .checking: Color(nsColor: .systemOrange)
        case .running: Color(nsColor: .systemGreen)
        case .unavailable: Color(nsColor: .systemRed)
        }
    }

    private var title: String {
        switch status {
        case .checking: "Checking Runtime"
        case .running: "Runtime Running"
        case .unavailable: "Runtime Unavailable"
        }
    }

    private var shortTitle: String {
        switch status {
        case .checking: "Checking…"
        case .running: "Running"
        case .unavailable: "Unavailable"
        }
    }

    private var badgeSymbol: String {
        switch status {
        case .checking: "ellipsis.circle.fill"
        case .running: "checkmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: CapsuleApp.menuBarIcon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                Image(systemName: badgeSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(color, CapsulePalette.background)
                    .offset(x: 4, y: 3)
            }
            .foregroundStyle(color)
            .frame(width: 22, height: 20)
            .accessibilityHidden(true)

            if showsLabel {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Apple container")
                        .font(.caption.weight(.semibold))
                    Text(shortTitle)
                        .font(.caption)
                        .foregroundStyle(color)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .help(title)
    }
}
