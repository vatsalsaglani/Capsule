import Foundation

extension PullProgress {
    /// Best-effort structured fields decoded from Apple `container pull`'s
    /// human-readable progress line. Unknown and malformed clauses are left
    /// out while `message` remains available verbatim to every caller.
    public var details: Details? {
        Details.parse(message)
    }

    public struct Details: Sendable, Equatable {
        /// An open value rather than a closed enum: the runtime may add pull
        /// phases without requiring a CapsuleKit API change.
        public struct Phase: RawRepresentable, Sendable, Equatable, Hashable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let phase: Phase
        public let stageIndex: Int
        public let stageCount: Int
        public let completedBlobs: Int?
        public let totalBlobs: Int?
        public let percent: Int?
        public let transferredBytes: UInt64?
        public let totalBytes: UInt64?
        public let bytesPerSecond: UInt64?
        public let elapsed: Duration

        fileprivate static func parse(_ raw: String) -> Self? {
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.first == "[",
                  let stageEnd = message.firstIndex(of: "]"),
                  message.last == "]",
                  let elapsedStart = message[..<message.index(before: message.endIndex)].lastIndex(of: "[")
            else { return nil }

            let stageText = message[message.index(after: message.startIndex)..<stageEnd]
            let stageParts = stageText.split(separator: "/", omittingEmptySubsequences: false)
            guard stageParts.count == 2,
                  let stageIndex = Int(stageParts[0]),
                  let stageCount = Int(stageParts[1]),
                  stageIndex > 0,
                  stageCount >= stageIndex
            else { return nil }

            let elapsedText = message[message.index(after: elapsedStart)..<message.index(before: message.endIndex)]
            guard elapsedText.last == "s",
                  let elapsedSeconds = Double(elapsedText.dropLast()),
                  elapsedSeconds.isFinite,
                  elapsedSeconds >= 0
            else { return nil }
            let elapsedMilliseconds = (elapsedSeconds * 1_000).rounded()
            // Double(Int64.max) rounds to 2^63, which is already outside
            // Int64. A strict representable-boundary check avoids a trapping
            // conversion at both the rounded boundary and overflow values.
            guard elapsedMilliseconds.isFinite,
                  elapsedMilliseconds >= 0,
                  elapsedMilliseconds < 9_223_372_036_854_775_808.0
            else { return nil }

            let bodyStart = message.index(after: stageEnd)
            guard bodyStart <= elapsedStart else { return nil }
            var body = String(message[bodyStart..<elapsedStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var clauses: [Substring] = []
            if body.last == ")", let open = body.lastIndex(of: "(") {
                let clauseStart = body.index(after: open)
                let clauseEnd = body.index(before: body.endIndex)
                clauses = body[clauseStart..<clauseEnd].split(separator: ",")
                body = String(body[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var percent: Int?
            if let lastWord = body.split(whereSeparator: \.isWhitespace).last,
               lastWord.last == "%",
               let parsed = Int(lastWord.dropLast()),
               (0...100).contains(parsed) {
                percent = parsed
                body.removeLast(lastWord.count)
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !body.isEmpty else { return nil }

            var completedBlobs: Int?
            var totalBlobs: Int?
            var transferredBytes: UInt64?
            var totalBytes: UInt64?
            var bytesPerSecond: UInt64?

            for rawClause in clauses {
                let clause = rawClause.trimmingCharacters(in: .whitespaces)
                if clause.hasSuffix(" blobs") {
                    let counts = clause.dropLast(" blobs".count).split(separator: " ")
                    if counts.count == 3,
                       counts[1] == "of",
                       let completed = Int(counts[0]),
                       let total = Int(counts[2]),
                       completed >= 0,
                       total >= completed {
                        completedBlobs = completed
                        totalBlobs = total
                    }
                } else if clause.hasSuffix("/s") {
                    bytesPerSecond = parseByteValue(String(clause.dropLast(2)), inheritedUnit: nil)?.bytes
                } else if let slash = clause.firstIndex(of: "/") {
                    let left = String(clause[..<slash])
                    let right = String(clause[clause.index(after: slash)...])
                    if let total = parseByteValue(right, inheritedUnit: nil) {
                        totalBytes = total.bytes
                        transferredBytes = parseByteValue(left, inheritedUnit: total.unit)?.bytes
                    }
                }
            }

            return Self(
                phase: Phase(rawValue: body),
                stageIndex: stageIndex,
                stageCount: stageCount,
                completedBlobs: completedBlobs,
                totalBlobs: totalBlobs,
                percent: percent,
                transferredBytes: transferredBytes,
                totalBytes: totalBytes,
                bytesPerSecond: bytesPerSecond,
                elapsed: .milliseconds(Int64(elapsedMilliseconds))
            )
        }

        private static func parseByteValue(
            _ raw: String,
            inheritedUnit: String?
        ) -> (bytes: UInt64, unit: String)? {
            let compact = raw.trimmingCharacters(in: .whitespaces)
            guard !compact.isEmpty else { return nil }

            let parts = compact.split(whereSeparator: \.isWhitespace)
            let numberText: Substring
            let unit: String
            if parts.count == 2 {
                numberText = parts[0]
                unit = String(parts[1])
            } else if parts.count == 1 {
                let token = parts[0]
                let numberEnd = token.firstIndex { !$0.isNumber && $0 != "." } ?? token.endIndex
                numberText = token[..<numberEnd]
                let suffix = String(token[numberEnd...])
                unit = suffix.isEmpty ? (inheritedUnit ?? "") : suffix
            } else {
                return nil
            }

            let multiplier: Double
            switch unit.lowercased() {
            case "bytes", "b": multiplier = 1
            case "kb": multiplier = 1_000
            case "mb": multiplier = 1_000_000
            case "gb": multiplier = 1_000_000_000
            case "tb": multiplier = 1_000_000_000_000
            default: return nil
            }
            guard let number = Double(numberText),
                  number.isFinite,
                  number >= 0
            else { return nil }
            let scaled = (number * multiplier).rounded()
            // Double(UInt64.max) is 2^64 rather than UInt64.max. Keep the
            // comparison strict before converting so boundary input fails
            // open instead of trapping.
            guard scaled.isFinite,
                  scaled >= 0,
                  scaled < 18_446_744_073_709_551_616.0
            else { return nil }
            return (UInt64(scaled), unit)
        }
    }
}
