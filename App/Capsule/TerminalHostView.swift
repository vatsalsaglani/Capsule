import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import TerminalKit

/// Wraps SwiftTerm's macOS `TerminalView` directly (plain `TerminalView` —
/// SwiftTerm's `LocalProcess`/`LocalProcessTerminalView` are deliberately
/// unused, S3 decision: `PTYExecSession` owns the PTY and the child process
/// directly; SwiftTerm here is pure terminal emulation/rendering, fed bytes
/// from `TerminalSession.output` and forwarding input/resize back through
/// the protocol). This is the one file in the app allowed to `import
/// SwiftTerm` — TerminalKit stays UI-free (AGENTS.md rule 1/2).
struct TerminalHostView: NSViewRepresentable {
    let session: any TerminalSession

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // Solid, always-dark surface — terminals are never translucent,
        // regardless of appearance mode (design rule, plan §6.2/§6.7; same
        // colors `ContainerInspector.logsTab` already uses).
        view.nativeBackgroundColor = NSColor(red: 0.086, green: 0.086, blue: 0.094, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        context.coordinator.startFeeding(view: view, session: session)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // `session` is fixed for the lifetime of a given `TerminalHostView`
        // instance (one host view per tab, per `TerminalTabsView`) — no
        // per-update work needed.
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stopFeeding()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // Swift 6.2 conformance isolation: `TerminalViewDelegate` itself is
    // `nonisolated`, so a `@MainActor` conformer must isolate the
    // conformance explicitly (`@MainActor TerminalViewDelegate`) — plain
    // `@MainActor` on the class alone isn't sufficient (verified live: the
    // compiler's `#ConformanceIsolation` diagnostic against real SwiftTerm,
    // see the learnings note).
    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        // `TerminalSession` isn't class-constrained (an existential can't be
        // `weak`) — held strongly for this view's lifetime instead; cleared
        // in `stopFeeding()` (called from `dismantleNSView`) rather than
        // relying on a weak reference to avoid an indefinite retain.
        private var session: (any TerminalSession)?
        private var feedTask: Task<Void, Never>?

        /// One `Task` per view, consuming `session.output` and feeding
        /// `TerminalView` — cancelled in `dismantleNSView`.
        func startFeeding(view: TerminalView, session: any TerminalSession) {
            self.session = session
            feedTask?.cancel()
            feedTask = Task { [weak view] in
                for await chunk in session.output {
                    guard let view, !Task.isCancelled else { return }
                    view.feed(byteArray: ArraySlice(chunk))
                }
            }
        }

        func stopFeeding() {
            feedTask?.cancel()
            feedTask = nil
            session = nil
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let session else { return }
            Task { await session.send(Data(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let session else { return }
            Task { await session.resize(columns: newCols, rows: newRows) }
        }

        // Everything below is a deliberate no-op (or the documented safe
        // default) — the Terminal tab doesn't yet act on title/cwd/scroll/
        // link/bell/clipboard/iTerm-content/range-changed notifications;
        // honest scoping (rule 10, AGENTS.md), not an oversight.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
