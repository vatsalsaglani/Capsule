/// Health state machine per service: starting → healthy | unhealthy, gating
/// `depends_on: service_healthy` (plan §4.6). The probe loop (exec-based
/// checks via ContainerRuntime) lands in M3.
public enum HealthState: String, Sendable, Codable, Hashable {
    case starting
    case healthy
    case unhealthy
}

/// Resolved healthcheck ready for the probe loop. `CMD` becomes the argv
/// directly; `CMD-SHELL` becomes ["sh", "-c", command].
public struct HealthcheckPlan: Sendable, Codable, Equatable {
    public var argv: [String]
    public var interval: Duration
    public var timeout: Duration
    public var retries: Int
    public var startPeriod: Duration

    public init(
        argv: [String],
        interval: Duration = .seconds(30),
        timeout: Duration = .seconds(30),
        retries: Int = 3,
        startPeriod: Duration = .zero
    ) {
        self.argv = argv
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }
}
