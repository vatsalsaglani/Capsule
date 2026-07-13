import SwiftUI

struct CapsuleBadge: View {
    let title: String
    let systemImage: String?
    let color: Color

    init(_ title: String, systemImage: String? = nil, color: Color = CapsulePalette.accent) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
