# Frontend-resident supervision needs durable checkpoints, not a reconstructed timer

**Context:** Phase 3 made health probes, restart policies, and drift repair
survive the process boundary between the CLI, Capsule.app, and a later app
relaunch without adding the v1.1 LaunchAgent yet.

**Finding (Capsule on Apple `container` 1.1.x):** the runtime's polled state is
not enough to reconstruct supervisor intent. A generic stopped container does
not say whether Capsule's user stopped it, and a process relaunch otherwise
grants a healthcheck a new `start_period` and resets restart backoff. The
durable checkpoint therefore needs all of:

- desired running state and `stoppedByUser`, written before the runtime
  start/stop mutation;
- last health state, attempt, output, observation time, and container ID;
- restart attempts, absolute scheduled deadline, scheduled container ID,
  last error, and an explicit limitation;
- the resolved Compose document and exact source replay information.

On attach, the frontend first consumes an authoritative all-container snapshot
from the shared poller. A restored health observation is shown as stale until a
live probe arrives. If it belongs to the same container, the monitor probes
immediately instead of granting a fresh one-time `start_period`. An unfinished
restart sleeps only until the persisted absolute deadline. Every supervised
restart also rebuilds the Capsule-managed hosts block because a restarted
container may receive a different address.

Verification (2026-07-14, Swift 6.2):

```text
$ swift test --filter ComposeSupervisorTests
Test run with 5 tests in 0 suites passed

$ swift test --filter AppCoreTests
Test run with 75 tests in 0 suites passed
```

The matrix covers persisted health becoming live after relaunch, an `always`
restart resuming from the first app snapshot, user stop suppressing restart,
report-only reconcile making no mutation, safe heal restoring desired state,
and `on-failure` remaining paused when exit status is unavailable.

**Consequence:** `RuntimeSession` owns one structured supervisor task for the
app lifetime. Foreground `capsule compose up` owns supervision and logs until
interrupted. `up --detach` creates no hidden daemon and tells the user that
supervision requires the Capsule agent. All state remains Codable and UI-free
so the same supervisor can move behind the future `capsuled` XPC boundary.

