# Local diagnostics: delayed app termination and structured incident privacy

**Context:** P1 onboarding needed the same runtime doctor as the CLI, and P4
needed an honest crash/error approach without silently introducing telemetry.

**Finding (macOS AppKit / Swift 6):** an async cleanup task started from
`applicationWillTerminate` is best-effort; AppKit does not wait for it. A local
launch marker can be cleared reliably by returning `.terminateLater` from
`applicationShouldTerminate`, awaiting the marker write and runtime shutdown,
then calling `reply(toApplicationShouldTerminate:)`.

A marker left behind on the next launch proves only that the previous process
did not terminate cleanly. It cannot distinguish a crash from Force Quit,
SIGKILL, power loss, or machine shutdown. Signal-handler persistence is not a
safe replacement: allocation, JSON encoding, and filesystem operations are
not async-signal-safe.

The incident schema itself is the privacy boundary. It accepts only product-
owned enums plus an optional numeric code. There is no field or API for raw
`Error`, localized descriptions, stderr, argv, environment variables, Compose
YAML, project/container/image names, paths, usernames, or backtraces. History
is local-only versioned JSON, atomically replaced, capped by age/count/encoded
bytes, rate-limited for repeated identical failures, and exported only on an
explicit user action. Release-metadata networking lives in the separate
runtime doctor and never receives incident data.

Verification (2026-07-14, Swift 6.2):

```text
$ swift test --filter DiagnosticsTests
Test run with 6 tests in 0 suites passed
```

The tests cover dependency skips when the binary is absent, exact 1.x version
gating, stopped/update warning state, unclean-launch recovery, retention, and
the absence of freeform sensitive fields from JSON export.

**Consequence:** the UI says “Capsule did not terminate cleanly,” never “Capsule
crashed.” Onboarding, System, and `capsule doctor` consume one immutable
snapshot stream, while the local incident actor has no network or uploader API.

