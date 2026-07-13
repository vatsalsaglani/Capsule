import Foundation

/// PTY/exec session surface. `PTYExecSession` (P1C, spike S3) is the sole
/// conformer: it owns a raw PTY over `container exec -it` directly rather
/// than handing process ownership to SwiftTerm's `LocalProcess` — the
/// protocol exists so the App's SwiftTerm view (and any future CLI reuse)
/// never touches SwiftTerm's process machinery or the PTY fds directly.
public protocol TerminalSession: Sendable {
    var output: AsyncStream<Data> { get }
    func send(_ data: Data) async
    func resize(columns: Int, rows: Int) async
    func terminate() async

    /// Suspends until the session's underlying child process has exited
    /// (whether via a clean shell exit, the S3 cooperative-terminate
    /// sequence, or the container itself going away out from under an
    /// attached session). Returns the POSIX-style exit code (128+signal for
    /// a signaled child, matching shell convention) — `nil` only if the
    /// code genuinely could not be determined. **137 (128+SIGKILL) is the
    /// conventional "container went away" code** (S3, confirmed live): treat
    /// it as a clean "exited" state, not an error. Safe to call more than
    /// once and from multiple callers; every caller observes the same
    /// outcome once the session finishes.
    func waitUntilExit() async -> Int32?
}
