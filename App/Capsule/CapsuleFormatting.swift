import Foundation

enum CapsuleFormatting {
    static func bytes(_ value: UInt64, style: ByteCountFormatter.CountStyle = .memory) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: style)
    }

    static func memory(_ used: UInt64, limit: UInt64) -> String {
        guard limit > 0 else { return bytes(used) }
        return "\(bytes(used)) / \(bytes(limit))"
    }

    static func fraction(_ used: UInt64, of limit: UInt64) -> Double? {
        guard limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }
}
