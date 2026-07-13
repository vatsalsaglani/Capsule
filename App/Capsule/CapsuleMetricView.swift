import SwiftUI

struct CapsuleMetricView: View {
    let title: String
    let value: String
    let fraction: Double?
    var tint: Color = CapsulePalette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .accessibilityLabel(title)
                    .accessibilityValue(value)
            }
        }
    }
}
