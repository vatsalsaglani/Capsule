import Foundation
import Yams

/// Shared user-facing Compose rendering so CLI and app stay honest and
/// byte-for-byte consistent about the supported subset.
public enum ComposePresentation {
    public static let serviceDiscoveryExplanation =
        "Service-name discovery uses a Capsule-managed /etc/hosts block because Apple container 1.1 does not publish container-name DNS records. Capsule refreshes the block after starts and reconciliation."

    public static func resolvedConfiguration(_ document: ComposeDocument) throws -> String {
        try YAMLEncoder().encode(document.file)
    }
}
