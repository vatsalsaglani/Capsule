/// Restart policies are Capsule's job — the runtime does not have them
/// (plan §4.6). This module must stay UI-free and fully serializable: in v1.1
/// it moves into the `capsuled` LaunchAgent unchanged.
public enum RestartPolicy: Sendable, Equatable, Codable {
    case never
    case always
    case unlessStopped
    case onFailure(maxRetries: Int?)

    /// Docker semantics: a container the user explicitly stopped is never
    /// auto-restarted, regardless of policy.
    public func shouldRestart(exitCode: Int32, wasStoppedByUser: Bool, attemptsSoFar: Int) -> Bool {
        guard !wasStoppedByUser else { return false }
        switch self {
        case .never:
            return false
        case .always, .unlessStopped:
            return true
        case .onFailure(let maxRetries):
            guard exitCode != 0 else { return false }
            guard let maxRetries else { return true }
            return attemptsSoFar < maxRetries
        }
    }

    /// Docker-compatible backoff: 100 ms doubling per attempt, capped at 1 min.
    public static func backoffDelay(attempt: Int) -> Duration {
        let capped = min(max(attempt, 0), 16)
        return .milliseconds(min(100 << capped, 60_000))
    }
}
