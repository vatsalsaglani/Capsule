import SwiftUI

/// Semantic Graphite & Indigo tokens from plan §6.7. Runtime state never
/// uses these colors; state remains green/orange/red/gray through
/// `ContainerStateColor`.
enum CapsulePalette {
    static let accent = Color(nsColor: .systemIndigo)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let consoleBackground = Color(nsColor: .black)
    static let consoleInk = Color(nsColor: .white).opacity(0.92)

    static func selectionFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return accent.opacity(0.18) }
        if isHovered { return elevated.opacity(0.8) }
        return surface.opacity(0.72)
    }

    static func selectionStroke(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return accent.opacity(0.72) }
        if isHovered { return accent.opacity(0.25) }
        return hairline.opacity(0.8)
    }
}
