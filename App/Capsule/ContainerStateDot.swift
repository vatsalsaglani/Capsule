import SwiftUI

/// Semantic-state indicator (master plan §6.3/§6.7): color from
/// `ContainerStateColor` only, a small scale pulse (≈1.0→1.25→1.0) through
/// `CapsuleMotion.standard` whenever `status` changes. `accessibilityHidden`
/// itself — the row/inspector that places this dot is responsible for a
/// combined VoiceOver label ("api — running, healthy, port 8080" per §6.5),
/// not this view in isolation.
struct ContainerStateDot: View {
    let status: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseTrigger = 0

    var body: some View {
        Circle()
            .fill(ContainerStateColor.color(for: status))
            .frame(width: 8, height: 8)
            // Explicit 3-entry sequence (not `.allCases`, which would only
            // have 2 unique phases) so the pulse settles back at `.rest`
            // rather than stopping at `.peak` — `phaseAnimator(trigger:)`
            // plays through once per trigger change and holds the last phase.
            .phaseAnimator([PulsePhase.rest, .peak, .rest], trigger: pulseTrigger) { content, phase in
                content.scaleEffect(reduceMotion ? 1.0 : phase.scale)
            } animation: { _ in
                CapsuleMotion.standard
            }
            .onChange(of: status) { _, _ in
                // `accessibilityReduceMotion` → the color change alone
                // communicates the transition; no scale pulse (§6.5).
                guard !reduceMotion else { return }
                pulseTrigger += 1
            }
            .accessibilityHidden(true)
    }

    private enum PulsePhase: Equatable {
        case rest, peak

        var scale: CGFloat {
            switch self {
            case .rest: 1.0
            case .peak: 1.25
            }
        }
    }
}
