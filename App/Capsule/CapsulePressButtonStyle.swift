import SwiftUI

/// Immediate pointer-down feedback (plan §6.3). The scale settles through
/// the house spring and is disabled for Reduce Motion.
struct CapsulePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : CapsuleMotion.standard, value: configuration.isPressed)
    }
}
