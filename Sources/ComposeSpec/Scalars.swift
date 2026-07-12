import Foundation

/// YAML scalar that may arrive typed (string, bool, int, double) but that we
/// always treat as a string — e.g. `POSTGRES_PORT: 5432`.
public struct FlexibleString: Decodable, Sendable, Equatable {
    public let value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "true" : "false"
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleString.self,
                .init(codingPath: decoder.codingPath, debugDescription: "expected a YAML scalar")
            )
        }
    }
}

/// Compose fields that accept either a single string or a list of strings
/// (`command`, `entrypoint`, `env_file`, `tmpfs`, healthcheck `test`, …).
public enum StringOrList: Decodable, Sendable, Equatable {
    case single(String)
    case list([String])

    public var values: [String] {
        switch self {
        case .single(let value): [value]
        case .list(let values): values
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .single(string)
        } else if let list = try? container.decode([FlexibleString].self) {
            self = .list(list.map(\.value))
        } else {
            throw DecodingError.typeMismatch(
                StringOrList.self,
                .init(codingPath: decoder.codingPath, debugDescription: "expected string or list of strings")
            )
        }
    }
}

/// `environment` / `labels` / build `args`: map form (`KEY: value`) or list
/// form (`- KEY=value`, `- KEY` for pass-through with a nil value).
public struct EnvironmentMap: Decodable, Sendable, Equatable {
    public let entries: [String: String?]

    public init(entries: [String: String?]) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let map = try? container.decode([String: FlexibleString?].self) {
            entries = map.mapValues { $0?.value }
        } else if let list = try? container.decode([String].self) {
            var parsed: [String: String?] = [:]
            for item in list {
                if let separator = item.firstIndex(of: "=") {
                    parsed[String(item[..<separator])] = String(item[item.index(after: separator)...])
                } else {
                    parsed[item] = String?.none
                }
            }
            entries = parsed
        } else {
            throw DecodingError.typeMismatch(
                EnvironmentMap.self,
                .init(codingPath: decoder.codingPath, debugDescription: "expected map or KEY=VALUE list")
            )
        }
    }
}

/// Parses compose duration strings ("5s", "1m30s", "500ms", "2h") into
/// `Duration`. Returns nil for anything it does not understand.
public enum ComposeDuration {
    public static func parse(_ text: String) -> Duration? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var total = Duration.zero
        var matched = false
        var remainder = Substring(trimmed)
        while let match = remainder.prefixMatch(of: /(\d+)(ms|s|m|h)/) {
            guard let amount = Int64(match.1) else { return nil }
            switch match.2 {
            case "ms": total += .milliseconds(amount)
            case "s": total += .seconds(amount)
            case "m": total += .seconds(amount * 60)
            case "h": total += .seconds(amount * 3600)
            default: return nil
            }
            matched = true
            remainder = remainder[match.range.upperBound...]
        }
        guard matched, remainder.isEmpty else { return nil }
        return total
    }
}
