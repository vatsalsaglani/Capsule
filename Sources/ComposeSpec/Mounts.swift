import Foundation

public enum ComposeSyntaxError: Error, Equatable, Sendable {
    case malformedPort(String)
    case malformedVolume(String)
}

/// `ports:` entry — short syntax ("8080:80", "127.0.0.1:8080:80/udp", 80) or
/// long syntax ({target, published, protocol, host_ip}).
/// Maps 1:1 onto `container run -p` (plan §4.3).
public struct PortMapping: Codable, Sendable, Hashable {
    public var hostIP: String?
    public var published: Int?
    public var target: Int
    public var proto: String

    public init(hostIP: String? = nil, published: Int?, target: Int, proto: String = "tcp") {
        self.hostIP = hostIP
        self.published = published
        self.target = target
        self.proto = proto
    }

    /// Note: IPv6 host literals and port ranges are not supported yet — they
    /// surface as `.malformedPort`, never as silent misparses.
    public init(shortSyntax: String) throws {
        var spec = shortSyntax
        var proto = "tcp"
        if let slash = spec.firstIndex(of: "/") {
            proto = String(spec[spec.index(after: slash)...])
            spec = String(spec[..<slash])
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let target = Int(parts[0]) else { throw ComposeSyntaxError.malformedPort(shortSyntax) }
            self.init(published: nil, target: target, proto: proto)
        case 2:
            guard let published = Int(parts[0]), let target = Int(parts[1]) else {
                throw ComposeSyntaxError.malformedPort(shortSyntax)
            }
            self.init(published: published, target: target, proto: proto)
        case 3:
            guard let published = Int(parts[1]), let target = Int(parts[2]) else {
                throw ComposeSyntaxError.malformedPort(shortSyntax)
            }
            self.init(hostIP: parts[0], published: published, target: target, proto: proto)
        default:
            throw ComposeSyntaxError.malformedPort(shortSyntax)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case target, published, proto = "protocol", hostIP = "host_ip"
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let port = try? single.decode(Int.self) {
            self.init(published: nil, target: port)
            return
        }
        if let short = try? single.decode(String.self) {
            self = try PortMapping(shortSyntax: short)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = try container.decode(FlexibleString.self, forKey: .target)
        guard let targetPort = Int(target.value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .target, in: container, debugDescription: "port must be an integer"
            )
        }
        let published = try container.decodeIfPresent(FlexibleString.self, forKey: .published)
        self.init(
            hostIP: try container.decodeIfPresent(String.self, forKey: .hostIP),
            published: published.flatMap { Int($0.value) },
            target: targetPort,
            proto: try container.decodeIfPresent(String.self, forKey: .proto) ?? "tcp"
        )
    }
}

/// `volumes:` entry on a service — short syntax ("./src:/app:ro",
/// "pgdata:/var/lib/postgresql/data") or long syntax
/// ({type, source, target, read_only}). Named volumes become
/// `container volume` resources; binds stay host paths (plan §4.3).
public struct VolumeMount: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case volume, bind, tmpfs
    }

    public var kind: Kind
    public var source: String?
    public var target: String
    public var readOnly: Bool

    public init(kind: Kind, source: String?, target: String, readOnly: Bool = false) {
        self.kind = kind
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    public init(shortSyntax: String) throws {
        let parts = shortSyntax.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            // Anonymous volume: just a container path.
            self.init(kind: .volume, source: nil, target: parts[0])
        case 2, 3:
            let source = parts[0]
            var readOnly = false
            if parts.count == 3 {
                switch parts[2] {
                case "ro": readOnly = true
                case "rw": readOnly = false
                default: throw ComposeSyntaxError.malformedVolume(shortSyntax)
                }
            }
            let isBind = source.hasPrefix("/") || source.hasPrefix("./")
                || source.hasPrefix("../") || source.hasPrefix("~")
            self.init(kind: isBind ? .bind : .volume, source: source, target: parts[1], readOnly: readOnly)
        default:
            throw ComposeSyntaxError.malformedVolume(shortSyntax)
        }
        guard target.hasPrefix("/") else { throw ComposeSyntaxError.malformedVolume(shortSyntax) }
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "type", source, target, readOnly = "read_only"
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let short = try? single.decode(String.self) {
            self = try VolumeMount(shortSyntax: short)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            target: try container.decode(String.self, forKey: .target),
            readOnly: try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        )
    }
}
