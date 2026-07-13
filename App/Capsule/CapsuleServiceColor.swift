import SwiftUI

/// Stable identity colors for Compose services and multiplexed logs. These
/// never communicate runtime state; state remains on `ContainerStateColor`.
enum CapsuleServiceColor {
    private static let palette: [NSColor] = [
        .systemIndigo, .systemBlue, .systemPurple, .systemPink,
        .systemTeal, .systemCyan,
    ]

    static func color(for service: String) -> Color {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in service.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Color(nsColor: palette[Int(hash % UInt64(palette.count))])
    }
}
