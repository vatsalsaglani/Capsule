import Foundation

public struct SemanticVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Extracts the first x.y.z occurrence from arbitrary text, e.g.
    /// "container CLI version 1.1.0 (build: release, commit: 5973b9c)".
    public init?(firstIn text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public enum ContainerRunState: String, Sendable, Equatable {
    case running
    case stopped
    case unknown
}

public struct ContainerSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let status: String
    public let imageReference: String?
    public let addresses: [String]

    public init(id: String, status: String, imageReference: String?, addresses: [String]) {
        self.id = id
        self.status = status
        self.imageReference = imageReference
        self.addresses = addresses
    }

    public var runState: ContainerRunState {
        ContainerRunState(rawValue: status.lowercased()) ?? .unknown
    }
}

extension ContainerSummary: Decodable {
    // Shape inferred from `container … --format json` v1.1.0 output: arrays of
    // objects with a nested `configuration` and lowerCamelCase keys (verified
    // for `image list`; `list` pending a populated runtime — spike S2, see
    // docs/learnings/2026-07-12-runtime-cli-observations.md). Decoding is
    // deliberately tolerant: only `configuration.id` is required.
    private enum CodingKeys: String, CodingKey {
        case status, configuration, networks
    }

    private struct Configuration: Decodable {
        struct ImageRef: Decodable { let reference: String? }
        let id: String
        let image: ImageRef?
    }

    private struct NetworkAttachment: Decodable { let address: String? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try container.decode(Configuration.self, forKey: .configuration)
        let attachments = (try? container.decode([NetworkAttachment].self, forKey: .networks)) ?? []
        self.init(
            id: configuration.id,
            status: (try? container.decode(String.self, forKey: .status)) ?? "unknown",
            imageReference: configuration.image?.reference,
            addresses: attachments.compactMap(\.address)
        )
    }
}
