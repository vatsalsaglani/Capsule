# P2A — Compose engine (spec → plan → execution)

The core value: `up` a real multi-service project. Engine only — frontends
are P2B.

| | |
|---|---|
| Branch | `phase/p2a-compose-engine` |
| Depends on | **Wave-1 tasks (1–3): nothing.** Task 4+: P1A Contract PR (`FakeContainerRuntime`, `RunSpec`). Task 6: P0-S1 decision. Real-runtime smoke: P1A implementation merged |
| Blocks | P2B, P3 |
| Owns | `Sources/ComposeSpec/`, `Sources/ComposePlanner/`, `Sources/ComposeRuntime/`, `Sources/ProjectStore/`, their `Tests/`, `Fixtures/` |

**Read first:** `AGENTS.md` (rules 4, 5, 8 + `swift-concurrency-pro` routing
for ComposeRuntime); master plan §4 **in full** (pipeline, supported subset,
flag mappings §4.3, discovery §4.4, planner §4.5, store §4.7); learnings note
on the YAML Norway problem (why scalars decode via `FlexibleString`);
`docs/spikes/S1-*.md` when it exists. Run `design-an-interface` before fixing
the `ComposeRuntime` public API (P2B and P3 both consume it).

## Deliverables (ordered; 1–3 need no runtime contract)

1. **Interpolation + environment wiring:** apply `Interpolation` per YAML
   scalar (not raw text — see the NOTE in `ComposeParser`), sourcing from
   process env + `.env` + `--env-file` with documented compose precedence.
   Golden tests for precedence and `${VAR:?err}` failure surfacing through
   `SupportReport`.
2. **Config-hash:** stable, canonical hash of the fully-resolved per-service
   spec → the `capsule.config-hash` label value. Must be insensitive to key
   order, sensitive to any semantic change; golden-tested.
3. **Planner v2:** diff desired vs *observed* state (injected as data — keep
   the planner pure): unchanged hash → no-op, changed → recreate + dependents
   restart in DAG order; `--force-recreate`/`--no-deps` escape hatches;
   independent branches emitted as parallel step *layers* (pulls/builds
   concurrent, starts respect DAG); `waitHealthy` gates only dependents with
   `service_healthy` (fix the v0 over-serialization noted in `Planner.swift`).
   Hundreds of golden plan tests are cheap here — write many (plan §7).
4. **Executor for real** (against `FakeContainerRuntime` first): every
   `PlanStep` → `ContainerRuntime` calls with deterministic names
   (`<project>-<service>-<n>`, `<project>_default`, `<project>_<vol>`) and the
   four `capsule.*` labels on every resource (AGENTS rule 5); §4.3 flag
   mappings via `RunSpec`; layer-parallel execution with structured
   concurrency; progress via the existing `ComposeEvent` bus; failure
   injection tests (pull fails, container dies mid-up, partial rollback
   behavior documented).
5. **ProjectStore integration:** `resolved-compose.json` (model + support
   report), `state.json` (desired state, per-service hashes) per master plan
   §4.7 layout; atomic, versioned (rule 8).
6. **S1 decision implemented:** whatever the spike chose (dns-search flags in
   `RunSpec` / hosts injection step / proxy) + the resolution explanation
   `compose config --report` will print (P2B renders it).
7. **Down/reconcile primitives:** enumerate project resources by label,
   ordered teardown (`down [--volumes]`), orphan detection — engine APIs only.

## Verification

`swift build && swift test` (the bulk of proof is fake-based + golden);
after P1A's implementation merges, one real smoke on this machine:
`Fixtures/compose/basic-web-db.yaml` up → `curl localhost:8080` → down →
volumes survive down without `--volumes`, are gone with it. Record any
runtime surprises as learnings (that's the point of the loop).
`swift-concurrency-pro` pass over the executor.

## Out of scope

CLI/App wiring (P2B) · health probes and restart policies (P3 — but your
`waitHealthy` step must expose a hook P3 can implement) · `profiles`/
`extends`/multi-file (v1.1+, keep them in `SupportScanner.deferredServiceKeys`).
