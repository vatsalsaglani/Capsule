import Foundation

/// Compose variable interpolation: `$VAR`, `${VAR}`, `${VAR:-default}`,
/// `${VAR-default}`, `${VAR:?error}`, `${VAR?error}`, `$$` escape.
///
/// NOTE(M2): not yet wired into `ComposeParser` — compose interpolates at the
/// YAML scalar level, so the parser must apply this per scalar before decode,
/// not to the raw document text. Tracked in docs/ROADMAP.md Phase 2.
public enum Interpolation {
    public struct MissingVariableError: Error, Equatable, Sendable {
        public let variable: String
        public let message: String
    }

    public static func interpolate(_ input: String, variables: [String: String]) throws -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "$" else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }
            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append("$")
                break
            }
            if input[next] == "$" {
                output.append("$")
                index = input.index(after: next)
            } else if input[next] == "{" {
                guard let close = input[next...].firstIndex(of: "}") else {
                    output.append(contentsOf: input[index...])
                    break
                }
                let token = String(input[input.index(after: next)..<close])
                output.append(try resolve(token: token, variables: variables))
                index = input.index(after: close)
            } else {
                var end = next
                while end < input.endIndex, input[end].isVariableNameCharacter {
                    end = input.index(after: end)
                }
                guard end > next else {
                    output.append("$")
                    index = next
                    continue
                }
                let name = String(input[next..<end])
                output.append(variables[name] ?? "")
                index = end
            }
        }
        return output
    }

    private static func resolve(token: String, variables: [String: String]) throws -> String {
        var nameEnd = token.startIndex
        while nameEnd < token.endIndex, token[nameEnd].isVariableNameCharacter {
            nameEnd = token.index(after: nameEnd)
        }
        let name = String(token[..<nameEnd])
        let rest = String(token[nameEnd...])
        let value = variables[name]

        if rest.isEmpty {
            return value ?? ""
        }
        if rest.hasPrefix(":-") {
            let fallback = String(rest.dropFirst(2))
            return (value?.isEmpty == false) ? value! : fallback
        }
        if rest.hasPrefix("-") {
            return value ?? String(rest.dropFirst(1))
        }
        if rest.hasPrefix(":?") {
            guard let value, !value.isEmpty else {
                throw MissingVariableError(variable: name, message: String(rest.dropFirst(2)))
            }
            return value
        }
        if rest.hasPrefix("?") {
            guard let value else {
                throw MissingVariableError(variable: name, message: String(rest.dropFirst(1)))
            }
            return value
        }
        // Unknown operator — pass the token through untouched so it is
        // visible rather than silently mangled.
        return "${\(token)}"
    }
}

private extension Character {
    var isVariableNameCharacter: Bool {
        isLetter || isNumber || self == "_"
    }
}
