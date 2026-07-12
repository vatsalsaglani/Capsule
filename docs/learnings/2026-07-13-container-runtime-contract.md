# P1A Contract PR — `ContainerRuntime` design decisions

**Context:** the P1A Contract PR (`c51ce9a`) widened `ContainerRuntime` from
5 to 23 methods, ran the `design-an-interface` skill against the shape, and
had the Advisor sign off the freeze. This note records *why* the shape landed
the way it did so a future agent doesn't re-litigate settled decisions before
the P1A implementation PR builds real bodies. Signatures themselves live in
`Sources/ContainerClient/ContainerRuntime.swift`; this is the rationale, not
a duplicate of the code.

## Findings

1. **Streaming return type is `async throws -> AsyncThrowingStream<_, Error>`
   (concrete boxed stream, eager async setup) — XPC-load-bearing, do not
   revise casually.** `logs`, `stats`, and `pullImage` all return this shape
   rather than `some AsyncSequence` or a generic associated type. Reasons:
   - XPC cannot ship an `AsyncSequence` across the wire at all — the future
     `XPCClient` conformance is a *local* adapter that receives XPC reply
     callbacks and re-emits them into a stream it builds locally via
     `AsyncThrowingStream.makeStream(of:)`'s continuation. The protocol
     method signature never crosses the XPC boundary itself; only the
     *elements* it yields do (all `Sendable` DTOs). A generic/opaque return
     type would work for the CLI client alone but gives the XPC client
     nothing to conform to.
   - An associated type (`associatedtype LogStream: AsyncSequence where
     LogStream.Element == LogLine`) was explicitly rejected: it breaks
     `any ContainerRuntime` as an existential, and `ComposeRuntime`'s
     `ComposeExecutor` stores exactly that existential
     (`private let runtime: any ContainerRuntime`, see
     `Sources/ComposeRuntime/ComposeExecutor.swift`). Protocols with
     associated-type requirements can't be used as existentials without
     `any` erasure gymnastics that would ripple through every consumer.

2. **`RunSpec` is a flat `Sendable, Hashable, Codable` struct with `var`
   properties and an `init(image:)` defaulting everything else — cheap to
   revise if a new flag shows up.** `Mount` is the one associated-value enum
   in the shape (`.bind`/`.volume`/`.tmpfs`), Codable via SE-0295 synthesis.
   `Hashable`+`Codable` on the whole struct is **load-bearing for §4.5
   config-hash reconciliation**: ComposeRuntime needs to hash a resolved
   `RunSpec` to detect "did this service's effective config change since the
   last `up`" and decide whether to recreate it — a struct that isn't
   `Hashable` (or whose hash isn't stable across encode/decode round-trips)
   can't back that comparison. Everything else about `RunSpec` (field list,
   optionality, defaults) is ordinary API surface and can change without
   touching the config-hash mechanism, as long as `Hashable`/`Codable`
   conformance is preserved.

3. **`stats` is tick-batched: `AsyncThrowingStream<[StatsSample], Error>`,
   not `AsyncThrowingStream<StatsSample, Error>` — a deliberate deviation
   from the P1A phase-package sketch's `stats(ids) -> AsyncThrowingStream<
   StatsSample,_>`.** `container stats --format json` emits one JSON *array*
   per tick, one element per requested container (spike S2 finding #9) — the
   tick is the natural unit of "a moment in time across N containers."
   Flattening to one `StatsSample` per stream element would need an
   artificial re-grouping step downstream (buffer N elements, guess when a
   tick ends) to reconstruct what the CLI already hands over pre-grouped.
   Keeping the array-per-tick framing is cheap to revise if a future
   consumer wants per-container streams instead — it would be a wrapper
   over this shape, not a signature change here.

4. **Error surface is a single flat `RuntimeError` enum plus
   `.notImplemented(operation:)`, not per-domain errors — cheap to revise.**
   `ImageError`/`VolumeError`/`NetworkError` etc. were considered and
   rejected as premature: every real failure mode observed so far (spike
   S1/S2) reduces to "binary missing," "command exited non-zero with
   stderr," "decode failed," or (Contract-PR-only) "not implemented yet."
   Splitting by resource domain before a second failure *shape* is observed
   would be speculative generality; revisit if/when a domain grows a
   genuinely structured failure (e.g. a typed conflict error for
   config-hash recreation) that `commandFailed`'s flat stderr string can't
   represent usefully.

5. **`FakeContainerRuntime` is a deliberately dumb actor — cheap to revise.**
   It holds canned per-method responses, an `Equatable` `Call` log recording
   every invocation with its exact arguments, and per-operation error
   injection (`setError`/`clearError`). It **never simulates state
   transitions** (e.g. calling `startContainer` does not flip a container's
   status to `"running"` in `containersValue`) — tests that need "start,
   then list shows running" must call `setContainers` again themselves. This
   keeps the fake's behavior fully predictable and keeps `ComposeExecutor`/
   `Supervisor` tests from accidentally depending on emergent fake behavior
   that the real CLI doesn't guarantee either.

## Consequences

- Do not propose replacing the streaming methods' return type with an
  associated type or `some AsyncSequence` without first checking whether it
  still composes with `any ContainerRuntime` at `ComposeExecutor`'s call
  site — item 1 is the one XPC-load-bearing decision in this note.
- Items 2–5 are ordinary API surface and can be revised in a normal PR if a
  concrete need arises; they don't need another `design-an-interface` pass
  unless the revision also touches item 1's existential/XPC constraint.
- `Sources/ContainerClientTestSupport/FakeContainerRuntime.swift` staying
  "dumb" (item 5) is a testing-philosophy decision, not a technical
  constraint — a smarter simulating fake could exist as a *different* type
  later without touching this one.
