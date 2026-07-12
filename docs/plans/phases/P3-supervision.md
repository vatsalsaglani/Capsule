# P3 — Supervision & fidelity

Healthchecks, restart policies, drift reconcile — the behaviors the runtime
doesn't have and users assume exist. Runs **after** P1A + P2A merge (it
extends both of their surfaces); mostly a single worktree.

| | |
|---|---|
| Branch | `phase/p3-supervision` |
| Depends on | P1A merged (exec for probes, exit events from Poller), P2A merged (executor hooks, ProjectStore state) |
| Blocks | P4 |
| Owns | `Sources/Supervisor/` + `Tests/SupervisorTests/`; agreed extension points in `Sources/ComposeRuntime/` (coordinate: P2A is done by now, so no live conflict — but keep executor edits surgical); `App/Capsule/` additions for volumes/networks/graph views if P1B didn't take them |

**Read first:** `AGENTS.md` (rule 6 is the defining constraint: **no UI
imports, fully serializable state — this module becomes the `capsuled`
LaunchAgent in v1.1 unchanged**); master plan §4.6 in full; existing
`RestartPolicy`/`HealthcheckPlan` (logic + backoff already tested — build on
them, don't rewrite); `swift-concurrency-pro` routing applies to everything
here.

## Deliverables

1. **Probe runner:** per-service actor executing `HealthcheckPlan.argv` via
   `ContainerRuntime.exec` with timeout; state machine
   `starting → healthy | unhealthy` honoring interval/retries/start_period;
   translate `Healthcheck` (ComposeSpec) → `HealthcheckPlan` including
   `CMD-SHELL` → `["sh","-c",…]`. Health transitions publish typed events.
2. **`service_healthy` gating:** implement the `waitHealthy` hook P2A exposed;
   `up` blocks dependents until healthy or fails with the probe's last output
   (never a bare "unhealthy").
3. **Restart watcher:** subscribe to exit events (Poller-synthesized), apply
   `RestartPolicy.shouldRestart` + `backoffDelay`; distinguish user-initiated
   stops (label/state via ProjectStore) from crashes; cap-and-log restart
   storms.
4. **Supervision residency (v1 decision, §4.6):** supervisor lives in the
   process that ran `up`; CLI `-d` prints the notice; app resumes supervision
   on launch via reconcile. All supervisor state serializes to
   `state.json` (ProjectStore) so resumption is possible — prove it with a
   kill-and-relaunch test.
5. **Drift reconcile:** observed (by `capsule.*` labels) vs desired
   (ProjectStore) → typed drift report → optional auto-heal; surfaces in
   `compose ps` and the Compose screen.
6. **Fidelity backlog:** `.env` precedence edge cases from P2A's notes;
   Volumes and Networks screens (list/create/delete/prune, "used by" via
   inspects); dependency-graph visualization (SwiftUI Canvas — the one
   deliberate showpiece; `apple-design` skill, springs restrained).
7. Failure-injection tests against `FakeContainerRuntime`: health flaps,
   probe timeouts, container dies during start_period, restart budget
   exhaustion (plan §7).

## Verification

Unit: the full state-machine matrix against fakes. Real-runtime: a fixture
with a deliberately failing healthcheck (`test: ["CMD","false"]`) marks
unhealthy after retries and blocks its dependent; `restart: always` container
killed with `container kill` comes back with visible backoff; `compose ps`
shows health columns; kill the supervising process mid-up → relaunch →
reconcile resumes cleanly.

## Out of scope

The `capsuled` LaunchAgent itself (v1.1 — but if any design choice would block
that move, stop and fix the design instead) · XPC event streams ·
`service_completed_successfully` beyond basic support.
