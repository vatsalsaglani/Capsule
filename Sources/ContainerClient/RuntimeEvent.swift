import Foundation

/// Synthesized domain events published by `RuntimePoller` onto an
/// `EventBus<RuntimeEvent>` (plan §2.1; P1A step 2, "Poller → EventBus").
/// Interface-grade — P1B's app-side consumers (Containers screen, menu-bar
/// extra) build directly against this shape, so field/case changes here
/// ripple outward; treat it with the same care as the frozen
/// `ContainerRuntime` protocol.
public enum RuntimeEvent: Sendable, Equatable {
    /// Published on poller start (first successful `listContainers`) and
    /// again immediately after an outage ends (`runtimeBecameAvailable`) —
    /// gives every consumer a full resync point instead of having to replay
    /// individual diffs from an unknown starting state.
    case snapshot([ContainerSummary])
    case containerAdded(ContainerSummary)
    case containerRemoved(id: String)
    case containerStateChanged(ContainerSummary, previousStatus: String)
    /// Edge-triggered: published exactly once when the runtime transitions
    /// from reachable to unreachable, never repeated on every failed poll
    /// tick during an ongoing outage.
    case runtimeBecameUnavailable(message: String)
    /// Edge-triggered counterpart to `runtimeBecameUnavailable`; always
    /// immediately followed by a `snapshot` (the poller's `listContainers`
    /// call that detected recovery becomes that snapshot).
    case runtimeBecameAvailable
}
