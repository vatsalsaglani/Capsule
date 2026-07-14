import AppCore
import SwiftUI

/// Presentation-only companion for an Images row. The actor-backed cache owns
/// source eligibility, networking, persistence, and validation; this view
/// simply keeps Capsule's blue disc visible until a supported logo is ready.
struct ContainerImageIcon: View {
    let reference: String
    let cache: ImageIconCache

    @ScaledMetric(relativeTo: .headline) private var iconSize = 20.0
    @State private var logo: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(CapsulePalette.accent.opacity(0.16))
            Circle()
                .stroke(CapsulePalette.accent.opacity(0.58), lineWidth: 1)

            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(iconSize * 0.18)
            } else {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: iconSize * 0.62, weight: .medium))
                    .foregroundStyle(CapsulePalette.accent)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
        .task(id: reference) {
            logo = nil
            let data = await cache.data(for: reference)
            guard !Task.isCancelled else { return }
            logo = data.flatMap(NSImage.init(data:))
        }
    }
}
