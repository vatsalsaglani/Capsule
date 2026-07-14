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

public enum ContainerRunState: String, Sendable, Hashable, Codable {
    case running
    case stopped
    case unknown
}

public struct ContainerSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let status: String
    public let imageReference: String?
    public let addresses: [String]
    public let ports: [PortMapping]
    public let labels: [String: String]

    public init(
        id: String,
        status: String,
        imageReference: String?,
        addresses: [String],
        ports: [PortMapping] = [],
        labels: [String: String] = [:]
    ) {
        self.id = id
        self.status = status
        self.imageReference = imageReference
        self.addresses = addresses
        self.ports = ports
        self.labels = labels
    }

    public var runState: ContainerRunState {
        ContainerRunState(rawValue: status.lowercased()) ?? .unknown
    }
}

extension ContainerSummary: Decodable {
    // Shape pinned by a populated runtime capture (spike S2, 2026-07-13; see
    // docs/learnings/2026-07-12-runtime-cli-observations.md finding #3 for
    // the full two-container `container list --all --format json` capture).
    // `id` (top-level) and `status.state` are required and throw on absence —
    // shape drift on these structural keys should surface loudly, not fall
    // back silently. `ports`/`labels`/`addresses` default to empty when their
    // source keys are legitimately absent (e.g. no published ports) — that is
    // not drift, just an empty resource.
    //
    // Note there is no top-level `status` string or top-level `networks` key
    // in real output (both are dead `CodingKey`s from before S2) — `status`
    // is an object (`{networks, startedDate, state}`) and resolved network
    // info lives at `status.networks[]`, not a top-level `networks` array.
    private enum CodingKeys: String, CodingKey {
        case id, status, configuration
    }

    private enum StatusKeys: String, CodingKey {
        case state, networks
    }

    private enum ConfigurationKeys: String, CodingKey {
        case image, publishedPorts, labels
    }

    private enum ImageKeys: String, CodingKey {
        case reference
    }

    private struct ResolvedNetworkAttachment: Decodable {
        let ipv4Address: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)

        let statusContainer = try container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        let status = try statusContainer.decode(String.self, forKey: .state)
        let attachments = (try? statusContainer.decode([ResolvedNetworkAttachment].self, forKey: .networks)) ?? []
        let addresses = attachments.compactMap(\.ipv4Address).map(strippingCIDRSuffix)

        var imageReference: String?
        var ports: [PortMapping] = []
        var labels: [String: String] = [:]
        if let configuration = try? container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration) {
            if let imageContainer = try? configuration.nestedContainer(keyedBy: ImageKeys.self, forKey: .image) {
                imageReference = try imageContainer.decodeIfPresent(String.self, forKey: .reference)
            }
            ports = (try? configuration.decode([PortMapping].self, forKey: .publishedPorts)) ?? []
            labels = (try? configuration.decode([String: String].self, forKey: .labels)) ?? [:]
        }

        self.init(id: id, status: status, imageReference: imageReference, addresses: addresses, ports: ports, labels: labels)
    }
}
