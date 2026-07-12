import SwiftUI

/// Container run-state → color, and nothing else (master plan §6.7 rule 1:
/// "accent never means state" — an indigo state dot is a bug). Every
/// container-state color in the app must go through this one mapping.
///
/// Takes the *raw* status string, not `ContainerRunState`, because the
/// verified runtime today only ever emits `"running"`/`"stopped"` (spike
/// S2) — collapsing everything else into `ContainerRunState.unknown` would
/// lose the starting/stopping/error distinctions the design spec calls for.
/// `"starting"`/`"stopping"`/error-shaped strings are handled here
/// defensively for forward-compatibility (exercised today only by the
/// `#if DEBUG` scripted feel-prototype demo, not a claim about currently-
/// observed runtime behavior — rule 10, AGENTS.md).
enum ContainerStateColor {
    static func color(for status: String) -> Color {
        switch status.lowercased() {
        case "running":
            return Color(nsColor: .systemGreen)
        case "starting", "stopping":
            return Color(nsColor: .systemOrange)
        case "stopped", "created":
            return Color(nsColor: .systemGray)
        default:
            let lowered = status.lowercased()
            if lowered.contains("error") || lowered.contains("fail") {
                return Color(nsColor: .systemRed)
            }
            return Color(nsColor: .systemGray)
        }
    }
}
