import Foundation

/// PTY/exec session surface. The SwiftTerm-backed implementation over
/// `container exec -it` lands in M1 (plan §3, spike S3); the protocol exists
/// now so ViewModels and the compose engine never touch SwiftTerm directly.
public protocol TerminalSession: Sendable {
    var output: AsyncStream<Data> { get }
    func send(_ data: Data) async
    func resize(columns: Int, rows: Int) async
    func terminate() async
}
