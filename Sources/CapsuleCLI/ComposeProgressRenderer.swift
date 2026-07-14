import ComposePlanner
import ComposeRuntime
import ContainerClient
import Darwin
import Foundation

struct ComposeProgressCapabilities: Equatable {
    let isInteractive: Bool

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdoutIsTTY: Bool = isatty(STDOUT_FILENO) == 1
    ) -> Self {
        let termIsUseful = environment["TERM"]?.lowercased() != "dumb"
        let noColorAllowsUI = environment["NO_COLOR", default: ""].isEmpty
        let cliColorAllowsUI = environment["CLICOLOR"] != "0"
        let ci = environment["CI"].map(isTruthy) ?? false
        return Self(
            isInteractive: stdoutIsTTY && termIsUseful && noColorAllowsUI && cliColorAllowsUI && !ci
        )
    }

    private static func isTruthy(_ raw: String) -> Bool {
        !["", "0", "false", "no", "off"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct ComposeTerminalSize: Equatable {
    let columns: Int
    let rows: Int

    static func current() -> Self {
        var value = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &value) == 0 else {
            return Self(columns: 80, rows: 24)
        }
        return Self(
            columns: value.ws_col > 0 ? Int(value.ws_col) : 80,
            rows: value.ws_row > 0 ? Int(value.ws_row) : 24
        )
    }
}

/// Stateful, CLI-only projection of Compose events. It deliberately consumes
/// the existing engine event contract so AppCore and future XPC clients are
/// unaffected by terminal capabilities.
struct ComposeProgressRenderer {
    private struct Entry {
        let step: PlanStep
        var message: String?
        var details: PullProgress.Details?
        var lastPlainPhase: String?
        var lastPlainPercentBucket: Int?
        var lastPlainHeartbeat: Int64?
        var emittedUnknown = false
        var diagnostics: [String] = []
    }

    private struct StepStyle {
        let icon: String
        let kind: String
        let service: String?
        let subject: String
        let isBuild: Bool
    }

    private struct RowSegment {
        let text: String
        let serviceColorKey: String?
    }

    private var interactive: Bool
    private var didDegrade = false
    private var active: [PlanStep: Entry] = [:]
    private var renderedLineCount = 0
    private var lastRenderedRows: [String] = []
    private var lastRedrawNanoseconds: UInt64 = 0
    private let write: (String) -> Void
    private let terminalSize: () -> ComposeTerminalSize
    private let nowNanoseconds: () -> UInt64

    init(
        capabilities: ComposeProgressCapabilities,
        write: @escaping (String) -> Void,
        terminalSize: @escaping () -> ComposeTerminalSize = ComposeTerminalSize.current,
        nowNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        interactive = capabilities.isInteractive
        self.write = write
        self.terminalSize = terminalSize
        self.nowNanoseconds = nowNanoseconds
    }

    static func standard() -> Self {
        Self(capabilities: .detect()) { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    mutating func consume(_ event: ComposeEvent) {
        switch event {
        case .operationStarted, .operationCompleted:
            break

        case .stepStarted(let step):
            active[step] = Entry(step: step)
            if interactive {
                redraw(force: true)
            } else {
                emitPlain("\(plainPrefix(for: step)) START \(style(for: step).subject)")
            }

        case .stepOutput(let step, let rawMessage):
            let message = Self.sanitize(rawMessage)
            var entry = active[step] ?? Entry(step: step)
            let details = PullProgress(message: rawMessage).details
            let becameDeterminate = entry.details == nil && details != nil
            entry.message = message
            entry.details = details
            if details == nil, !message.isEmpty, entry.diagnostics.last != message {
                entry.diagnostics.append(message)
                if entry.diagnostics.count > 2 { entry.diagnostics.removeFirst() }
            }
            active[step] = entry

            if style(for: step).isBuild {
                emitPermanent(interactive
                    ? "\(coloredServicePrefix(for: step))\(message)"
                    : "\(plainPrefix(for: step)) \(message)")
            } else if interactive {
                redraw(force: becameDeterminate)
            } else {
                emitBoundedPlainOutput(for: step)
            }

        case .stepCompleted(let step):
            active.removeValue(forKey: step)
            let line = interactive
                ? "\u{001B}[32m✓\u{001B}[0m \(coloredDescriptor(for: step)) complete"
                : "SUCCESS \(plainPrefix(for: step)) complete"
            emitPermanent(line)

        case .stepFailed(let step, let rawMessage):
            let entry = active.removeValue(forKey: step)
            let message = Self.sanitize(rawMessage)
            let diagnostic = entry.map { diagnosticSuffix(for: $0, failure: message) } ?? ""
            let line = interactive
                ? "\u{001B}[31m✗\u{001B}[0m \(coloredDescriptor(for: step)) failed: \(message)\(diagnostic)"
                : "FAILURE \(plainPrefix(for: step)) failed: \(message)\(diagnostic)"
            emitPermanent(line)

        case .operationOutput(let rawMessage):
            emitPermanent(Self.sanitize(rawMessage))

        case .warning(let rawMessage):
            let message = Self.sanitize(rawMessage)
            emitPermanent(interactive ? "\u{001B}[33m! warning\u{001B}[0m \(message)" : "WARNING \(message)")
        }
    }

    mutating func finish() {
        if interactive { clearDashboard() }
        active.removeAll(keepingCapacity: false)
        lastRenderedRows.removeAll(keepingCapacity: false)
    }

    private mutating func emitBoundedPlainOutput(for step: PlanStep) {
        guard var entry = active[step] else { return }
        if let details = entry.details {
            let phase = Self.sanitize(details.phase.rawValue).lowercased()
            let percentBucket = details.percent.map { $0 / 10 }
            let heartbeat = details.percent == nil ? details.elapsed.components.seconds / 10 : nil
            let shouldEmit = entry.lastPlainPhase != phase
                || (percentBucket != nil && entry.lastPlainPercentBucket != percentBucket)
                || (heartbeat != nil && entry.lastPlainHeartbeat != heartbeat)
            if shouldEmit {
                emitPlain("\(plainPrefix(for: step)) \(plainProgress(details))")
                entry.lastPlainPhase = phase
                entry.lastPlainPercentBucket = percentBucket
                entry.lastPlainHeartbeat = heartbeat
            }
        } else if !entry.emittedUnknown {
            emitPlain("\(plainPrefix(for: step)) \(entry.message ?? "working")")
            entry.emittedUnknown = true
        }
        active[step] = entry
    }

    private mutating func redraw(force: Bool) {
        guard interactive else { return }
        let size = terminalSize()
        if active.count > max(1, size.rows - 1) {
            degradeToPlain()
            return
        }

        let now = nowNanoseconds()
        if !force, lastRedrawNanoseconds != 0, now &- lastRedrawNanoseconds < 100_000_000 {
            return
        }
        let rows = active.values
            .sorted { sortKey(for: $0.step) < sortKey(for: $1.step) }
            .map { interactiveRow(for: $0, width: max(1, size.columns)) }
        guard force || rows != lastRenderedRows else { return }

        clearDashboard()
        for row in rows { write(row + "\n") }
        renderedLineCount = rows.count
        lastRenderedRows = rows
        lastRedrawNanoseconds = now
    }

    private mutating func degradeToPlain() {
        guard !didDegrade else { return }
        clearDashboard()
        interactive = false
        didDegrade = true
        emitPlain("PROGRESS terminal height exceeded; switching to plain output")
        for entry in active.values.sorted(by: { sortKey(for: $0.step) < sortKey(for: $1.step) }) {
            emitPlain("\(plainPrefix(for: entry.step)) \(entry.details.map(plainProgress) ?? "working")")
        }
    }

    private mutating func emitPermanent(_ line: String) {
        if interactive { clearDashboard() }
        write(Self.sanitizeOutputLine(line, preservingANSI: interactive) + "\n")
        if interactive { redraw(force: true) }
    }

    private func emitPlain(_ line: String) {
        write(Self.sanitizeOutputLine(line, preservingANSI: false) + "\n")
    }

    private mutating func clearDashboard() {
        guard renderedLineCount > 0 else { return }
        for _ in 0..<renderedLineCount {
            write("\u{001B}[1A\r\u{001B}[2K")
        }
        renderedLineCount = 0
        lastRenderedRows = []
    }

    private func interactiveRow(for entry: Entry, width: Int) -> String {
        let item = style(for: entry.step)
        let phase: String
        let percent: String
        var optional: [String] = []

        if let details = entry.details {
            phase = Self.sanitize(details.phase.rawValue).lowercased()
            percent = details.percent.map { "\($0)%" } ?? blobProgress(details)
            if width >= 66, let value = details.percent {
                optional.append(progressBar(percent: value, width: width >= 100 ? 18 : 10))
            }
            if width >= 88,
               let transferred = details.transferredBytes,
               let total = details.totalBytes {
                optional.append("\(Self.formatBytes(transferred))/\(Self.formatBytes(total))")
            }
            if width >= 110, let rate = details.bytesPerSecond {
                optional.append("\(Self.formatBytes(rate))/s")
            }
            if width >= 54 {
                optional.append(Self.formatDuration(details.elapsed))
            }
        } else {
            phase = entry.message ?? "preparing \(item.subject)"
            percent = spinner()
        }

        let displayedService = item.service.map {
            Self.truncateToCells($0, maxCells: max(1, min(18, width / 4)))
        }
        let service = displayedService.map { " \($0)" } ?? ""
        let mandatoryWidth = Self.visibleCellWidth(item.icon)
            + Self.visibleCellWidth(item.kind)
            + Self.visibleCellWidth(service)
            + Self.visibleCellWidth(percent)
            + 4
        let displayedPhase = Self.truncateToCells(phase, maxCells: max(1, width - mandatoryWidth))

        var segments = [RowSegment(text: "\(item.icon) \(item.kind)", serviceColorKey: nil)]
        if let displayedService, let originalService = item.service {
            segments.append(RowSegment(text: " ", serviceColorKey: nil))
            segments.append(RowSegment(text: displayedService, serviceColorKey: originalService))
        }
        var tail = "  \(displayedPhase)"
        if !percent.isEmpty { tail += " \(percent)" }
        if !optional.isEmpty { tail += " " + optional.joined(separator: " ") }
        segments.append(RowSegment(text: tail, serviceColorKey: nil))
        return render(segments: segments, maxCells: width)
    }

    private func plainProgress(_ details: PullProgress.Details) -> String {
        var parts = [Self.sanitize(details.phase.rawValue).lowercased()]
        if let percent = details.percent {
            parts.append("\(percent)%")
        } else if let completed = details.completedBlobs, let total = details.totalBlobs {
            parts.append("\(completed)/\(total) blobs")
        }
        parts.append(Self.formatDuration(details.elapsed))
        return parts.joined(separator: " ")
    }

    private func blobProgress(_ details: PullProgress.Details) -> String {
        if let completed = details.completedBlobs, let total = details.totalBlobs {
            return "\(completed)/\(total) blobs"
        }
        return spinner()
    }

    private func spinner() -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        return frames[Int((nowNanoseconds() / 100_000_000) % UInt64(frames.count))]
    }

    private func progressBar(percent: Int, width: Int) -> String {
        let filled = min(width, max(0, Int((Double(percent) / 100 * Double(width)).rounded(.down))))
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled) + "]"
    }

    private func coloredDescriptor(for step: PlanStep) -> String {
        let item = style(for: step)
        let service = item.service.map { " \(colored($0))" } ?? ""
        return "\(item.icon) \(item.kind)\(service) \(item.subject)"
    }

    private func coloredServicePrefix(for step: PlanStep) -> String {
        let item = style(for: step)
        return item.service.map { "\(item.icon) \(item.kind) \(colored($0))  " } ?? "\(item.icon) \(item.kind)  "
    }

    private func plainPrefix(for step: PlanStep) -> String {
        let item = style(for: step)
        return item.service.map { "\(item.kind.uppercased()) [\($0)]" } ?? item.kind.uppercased()
    }

    private func render(segments: [RowSegment], maxCells: Int) -> String {
        var remaining = max(0, maxCells)
        var rendered = ""
        for segment in segments where remaining > 0 {
            let text = Self.truncateToCells(segment.text, maxCells: remaining, ellipsis: false)
            remaining -= Self.visibleCellWidth(text)
            if let colorKey = segment.serviceColorKey, !text.isEmpty {
                rendered += colored(text, colorKey: colorKey)
            } else {
                rendered += text
            }
        }
        return rendered
    }

    private func colored(_ service: String, colorKey: String? = nil) -> String {
        "\u{001B}[\(Self.colorCode(for: colorKey ?? service))m\(service)\u{001B}[0m"
    }

    private func diagnosticSuffix(for entry: Entry, failure: String) -> String {
        let failureFolded = failure.lowercased()
        let diagnostics = entry.diagnostics.filter {
            !$0.isEmpty && !failureFolded.contains($0.lowercased())
        }
        guard !diagnostics.isEmpty else { return "" }
        return " — last diagnostic: " + diagnostics.joined(separator: " | ")
    }

    static func colorCode(for service: String) -> Int {
        // Swift's hashValue is intentionally randomized per process. FNV-1a
        // keeps service colors stable between runs and machines.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in service.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let palette = [36, 35, 34, 96, 95, 33, 94, 97] // green/red are state-only
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func sortKey(for step: PlanStep) -> String {
        let item = style(for: step)
        return "\(item.service ?? "")\u{0}\(item.kind)\u{0}\(item.subject)"
    }

    private func style(for step: PlanStep) -> StepStyle {
        switch step {
        case .ensureNetwork(let spec):
            StepStyle(icon: "◎", kind: "network", service: nil, subject: Self.sanitize(spec.name), isBuild: false)
        case .ensureVolume(let spec):
            StepStyle(icon: "▰", kind: "volume", service: nil, subject: Self.sanitize(spec.name), isBuild: false)
        case .ensureImage(let service, let image, _):
            StepStyle(icon: "⇣", kind: "image", service: Self.sanitize(service), subject: Self.sanitize(image), isBuild: false)
        case .ensureBuild(let service, let spec):
            StepStyle(icon: "◆", kind: "build", service: Self.sanitize(service), subject: Self.sanitize(spec.contextDirectory.lastPathComponent), isBuild: true)
        case .removeContainer(let service, let containerID):
            StepStyle(icon: "▣", kind: "container", service: Self.sanitize(service), subject: Self.sanitize(containerID), isBuild: false)
        case .ensureContainer(let service, let spec):
            StepStyle(icon: "▣", kind: "container", service: Self.sanitize(service), subject: Self.sanitize(spec.name ?? service), isBuild: false)
        case .stop(let service, let containerID, _):
            StepStyle(icon: "■", kind: "stop", service: Self.sanitize(service), subject: Self.sanitize(containerID), isBuild: false)
        case .start(let service, let reference):
            StepStyle(icon: "▶", kind: "start", service: Self.sanitize(service), subject: Self.sanitize(reference), isBuild: false)
        case .waitHealthy(let service, _, _):
            StepStyle(icon: "♥", kind: "health", service: Self.sanitize(service), subject: "healthy", isBuild: false)
        case .waitCompleted(let service, _):
            StepStyle(icon: "♥", kind: "health", service: Self.sanitize(service), subject: "completed", isBuild: false)
        case .refreshHosts(let targets):
            StepStyle(
                icon: "◎",
                kind: "network",
                service: nil,
                subject: Self.sanitize(targets.map(\.service).sorted().joined(separator: ",")),
                isBuild: false
            )
        }
    }

    static func sanitize(_ raw: String, limit: Int = 512) -> String {
        var scalars: [Unicode.Scalar] = []
        // 0 normal, 1 after ESC, 2 CSI, 3 OSC, 4 string control
        // (DCS/SOS/PM/APC), 5 OSC-after-ESC, 6 string-after-ESC.
        var ansiState = 0
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if ansiState == 1 {
                if scalar == "[" { ansiState = 2 }
                else if scalar == "]" { ansiState = 3 }
                else if scalar == "P" || scalar == "X" || scalar == "^" || scalar == "_" { ansiState = 4 }
                else { ansiState = 0 }
                continue
            }
            if ansiState == 2 {
                if (0x40...0x7E).contains(value) || value == 0x9C { ansiState = 0 }
                continue
            }
            if ansiState == 3 {
                if value == 0x07 || value == 0x9C { ansiState = 0 }
                else if value == 0x1B { ansiState = 5 }
                continue
            }
            if ansiState == 4 {
                if value == 0x9C { ansiState = 0 }
                else if value == 0x1B { ansiState = 6 }
                continue
            }
            if ansiState == 5 {
                ansiState = scalar == "\\" ? 0 : 3
                continue
            }
            if ansiState == 6 {
                ansiState = scalar == "\\" ? 0 : 4
                continue
            }
            if value == 0x1B { ansiState = 1; continue }
            if value == 0x9B { ansiState = 2; continue }
            if value == 0x9D { ansiState = 3; continue }
            if value == 0x90 || value == 0x98 || value == 0x9E || value == 0x9F {
                ansiState = 4
                continue
            }
            if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value) {
                if value == 0x09 || value == 0x0A || value == 0x0D { scalars.append(" ") }
                continue
            }
            scalars.append(scalar)
        }
        let normalized = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(limit))
    }

    private static func sanitizeOutputLine(_ line: String, preservingANSI: Bool) -> String {
        preservingANSI ? line.replacingOccurrences(of: "\r", with: "") : sanitize(line)
    }

    static func visibleCellWidth(_ value: String) -> Int {
        value.unicodeScalars.reduce(into: 0) { width, scalar in
            let measured = wcwidth(wchar_t(scalar.value))
            if measured >= 0 {
                width += Int(measured)
            } else if scalar.properties.canonicalCombiningClass != .notReordered
                        || (0xFE00...0xFE0F).contains(scalar.value)
                        || (0xE0100...0xE01EF).contains(scalar.value) {
                // Darwin's C-locale wcwidth returns -1 for non-ASCII; retain
                // the correct zero-width behavior for combining/selectors.
            } else {
                width += Self.isWideFallback(scalar.value) ? 2 : 1
            }
        }
    }

    static func truncateToCells(
        _ value: String,
        maxCells: Int,
        ellipsis: Bool = true
    ) -> String {
        guard maxCells > 0 else { return "" }
        guard visibleCellWidth(value) > maxCells else { return value }
        let ellipsisText = ellipsis && maxCells > 1 ? "…" : ""
        let contentBudget = maxCells - visibleCellWidth(ellipsisText)
        var result = ""
        var used = 0
        for character in value {
            let characterText = String(character)
            let characterWidth = visibleCellWidth(characterText)
            guard used + characterWidth <= contentBudget else { break }
            result.append(character)
            used += characterWidth
        }
        return result + ellipsisText
    }

    private static func isWideFallback(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || value == 0x2329 || value == 0x232A
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
            || (0x20000...0x3FFFD).contains(value)
    }

    private static func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = components.seconds + Int64(components.attoseconds / 1_000_000_000_000_000_000)
        return "\(seconds)s"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: value.rounded() == value ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
