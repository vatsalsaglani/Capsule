import SwiftUI

/// House motion style (master plan §6.3): critically damped, no bounce on
/// anything that merely appears — the single spring constant every
/// inspector/selection/state-dot transition in the app animates through.
/// Never write a bespoke `.spring(...)` literal elsewhere; add a *named*
/// case here if a genuinely different interaction (momentum-driven drag/
/// flick — §6.3's "bounce only follows momentum" exception) needs one.
enum CapsuleMotion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
}
