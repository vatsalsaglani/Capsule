# Capsule Roadmap

Phase-wise execution plan. Derived from the master plan
([docs/plans/apple-container-manager-plan.md](plans/apple-container-manager-plan.md) §5) —
that document is the source of truth for *why*; this one tracks *what and when*.
Update checkboxes as work lands; never delete rows, strike them through with a note.

**Executing a phase?** Use the self-contained work packages in
[docs/plans/phases/](plans/phases/README.md) — each is written to run in its
own git worktree by an independent agent, with file-ownership boundaries and
merge order defined in that folder's README. Package map: Phase 0 →
[P0](plans/phases/P0-spikes.md) · Phase 1 → [P1A](plans/phases/P1A-runtime-surface.md),
[P1B](plans/phases/P1B-app-runtime-manager.md), [P1C](plans/phases/P1C-terminal.md),
[P1D](plans/phases/P1D-runtime-install-update.md) · Phase 2 →
[P2A](plans/phases/P2A-compose-engine.md), [P2B](plans/phases/P2B-compose-frontends.md) ·
Phase 3 → [P3](plans/phases/P3-supervision.md) · Phase 4 →
[P4](plans/phases/P4-polish-release.md).

Releases happen on GitHub: alpha `v0.0.x` tags out of Phase 1, the public
`v0.1.0` at the end of Phase 4. CLI binaries attach to releases via
`.github/workflows/release.yml`; the notarized app dmg joins in Phase 4.

## Phase 0 — Spikes (1 week) — *de-risk before building*

Findings go to `docs/spikes/` (see the README there). S1 decides the service
discovery design (§4.4) and blocks Phase 2 planning details.

- [x] **S1 DNS/networks** *(decided 2026-07-13)* — bare-name DNS fails on both custom and default networks (`NXDOMAIN`); `--dns-search`/`--dns-domain` plumb into `resolv.conf` but don't help. Hosts injection verified non-sudo and ships as the default discovery mechanism; the search-domain primary path is sudo-gated (`system dns create`) and stays unverified pending a human. See [spike](spikes/S1-dns-service-discovery.md) and [learnings](learnings/2026-07-13-container-dns-discovery.md).
- [x] **S2 `--format json` coverage** *(fully verified 2026-07-13 with a populated runtime)* — populated `container list` shape captured; no table-only commands found (`system status`/`system df`/`stats` all support JSON; `inspect` family emits JSON unconditionally, no `--format` flag); `ContainerSummary` tightening list (ports, labels, networks, status) handed off to P1A. See [spike](spikes/S2-json-coverage.md) and [learnings](learnings/2026-07-12-runtime-cli-observations.md).
- [ ] **S3 PTY/exec** — SwiftTerm + `container exec -it` interactive quality (resize, colors, ctrl-c).
- [x] **S4 stats streaming** *(decided 2026-07-13, trimmed)* — format/stream half already resolved by P1A (streaming mode is one-shot; `stats(ids:)` polls `--no-stream` instead). This spike measured the cost: `--no-stream --format json` has a fixed ~2.2s wall-clock latency floor independent of N (N=1/5/10 all ~2.2-2.4s, cost dominated by round-trip wait, not CPU — apiserver 0.0% CPU under sustained polling). Recommend keeping the 2s `statsInterval` default (real update cadence ≈4.2s = call + sleep), pausing the poll when the sparkline UI isn't visible, no dedicated stats actor (P1B reuses `stats(ids:)` directly), no contention concern with the `ls` Poller. See [spike](spikes/S4-stats-cost.md) and [learnings](learnings/2026-07-13-stats-polling-cost.md).
- [x] **S5 build streaming + cancel** *(decided 2026-07-13)* — SIGTERM alone (matching today's `terminate()`) exits `container build` in well under 1s and leaves the `buildkit` builder consistent; even SIGKILL of the CLI left no orphaned build process inside the builder VM. Recommend implementing the SIGKILL-escalation TODO in `Subprocess` anyway as a general 5s-grace defense-in-depth contract for *all* spawned children (not a build-specific fix — none was needed). `--progress plain` confirmed line-oriented/ANSI-free, ready for P1A's `FileHandle.bytes → AsyncThrowingStream` build streaming. See [spike](spikes/S5-build-cancel.md) and [learnings](learnings/2026-07-13-build-cancellation.md).

## Phase 1 — Runtime manager MVP (3–4 weeks) → `v0.0.x` alpha

Manage the full container/image lifecycle without touching Terminal; app
survives runtime restarts and CLI absence gracefully.

- [x] Repo scaffold: CapsuleKit SPM monorepo, `ContainerRuntime` protocol, `CLIProcessClient` (list/start/stop/delete/version), version gate, `Subprocess` with timeout+cancellation
- [x] `capsule doctor` (binary, version, apiserver status, GitHub update check)
- [x] `capsule ls`; app skeleton: sidebar, live-polling Containers screen, menu-bar extra stub
- [x] P1A Contract PR: `ContainerRuntime` widened to the full system/containers/images/volumes/networks surface, `RunSpec`, `RuntimeModels` DTOs decoded against verbatim S2 JSON, `ContainerClientTestSupport`'s `FakeContainerRuntime` — signatures frozen; `CLIProcessClient` bodies beyond the original five (+`systemStatus`) are `notImplemented` stubs pending the P1A implementation PR
- [x] P1A implementation PR: `CLIProcessClient`'s remaining 17 methods get real bodies (`RunSpecArgvBuilder`'s golden-tested `create` argv, `SubprocessLineStream` for `logs`/`pullImage`, poll-loop `stats`); `Subprocess` SIGTERM→grace→SIGKILL escalation; additive `ContainerDetail.mounts`/`MountDetail`; `RuntimeGateway` decorator serializing same-resource mutations
- [x] Poller → EventBus → synthesized `RuntimeEvent`s (`RuntimePoller`, replaces the ViewModel's direct polling loop — app-side wiring is P1B)
- [x] Containers screen: inspect detail, logs (follow), stats sparkline, `container cp`, open-in-browser from port mappings *(P1B B2/B3/B7 — `container cp` deliberately deferred: not on the frozen `ContainerRuntime` contract, honestly noted in-app rather than faked, rule 10 AGENTS.md; everything else is engine/store/compile-level complete incl. B7 a11y labels/reduce-motion pass — interactive click-through and VoiceOver spot-check are still open human gates, not yet run)*
- [x] Images screen: list, pull with progress, tag, push, delete, prune, registry login *(P1B B4/B7 — push/prune/registry login deliberately deferred: not on the frozen `ContainerRuntime` contract, honestly noted in-app, rule 10 AGENTS.md; list/pull/tag/delete are engine/store/compile-level complete — interactive click-through (pull progress) is still an open human gate)*
- [x] System screen: runtime status/versions, `system df`, start/stop runtime, log viewer *(P1B B5/B7 — log viewer deliberately deferred: not on the frozen `ContainerRuntime` contract, honestly noted in-app, rule 10 AGENTS.md; status/df/start-stop are engine/store/compile-level complete — interactive click-through and VoiceOver spot-check are still open human gates)*
- [ ] Terminal: SwiftTerm over `container exec -it`, shell auto-detection, session tabs (add SwiftTerm dependency to TerminalKit)
- [ ] Runtime install/update UX: onboarding screen when CLI missing → download latest release `.pkg` from GitHub, guide install; update banner when `RuntimeUpdateChecker` finds a newer release
- [x] Menu-bar extra: runtime up/down, running count, stop-all *(P1B B6/B7 — engine/store/compile-level complete, fed by the shared `RuntimeSession`/`MenuBarStore`; interactive click-through (Stop All, Open Capsule) is still an open human gate)*
- [ ] Feel prototype (plan §6.6): sidebar/list/inspector + one live-updating row + terminal, reviewed frame-by-frame — *sets the craft bar before UI build-out* *(P1B B2/B7 — the `#if DEBUG` `ScriptedDemoSession`/`FeelPrototypeDemoView` window compiles and drives the real Containers screen through genuine poll-driven state transitions; terminal isn't in the prototype since Terminal (P1C) isn't built yet; the frame-by-frame human review this line is named for hasn't happened — left unticked until that gate runs)*
- [ ] Interactive onboarding/doctor screen in-app
- [ ] Tag `v0.0.1` alpha (dmg, unsigned OK for alpha; CLI tar.gz)

## Phase 2 — Compose core (3–4 weeks) → the launch demo

`capsule compose up/down/ps/logs/config/plan` for the §4.2 subset minus
health/restart; Compose screen in the app.

- [x] ComposeSpec: typed model for the supported subset, short/long syntax (ports, volumes), support report with fail-loud policy, interpolation utility, duration parsing
- [x] ComposePlanner: DAG from `depends_on`, cycle detection, deterministic sequential plan, `compose plan`/`config` CLI
- [ ] Wire interpolation + `.env`/`--env-file` into the parser (per-scalar, not raw text)
- [ ] Implement S1 decision: service discovery (DNS search domains, else hosts-injection fallback)
- [ ] ComposeRuntime: execute steps for real (volume/network create, `run -d` with labels `capsule.project/service/index/config-hash`, pulls with progress)
- [ ] Config-hash reconciliation: recreate only changed services, restart dependents in DAG order; `--force-recreate`, `--no-deps`
- [ ] Parallelize independent plan branches (pulls/builds concurrent, starts respect DAG)
- [ ] `compose up -d / down [--volumes] / ps / logs [-f] / restart / stop / start / exec / build / pull`
- [ ] ProjectStore: `project.json`, `resolved-compose.json`, `state.json`, per-service log spools
- [ ] Compose screen in app: project list, per-service status, project logs, up/down/restart, plan viewer

## Phase 3 — Supervision & fidelity (2–3 weeks)

- [ ] Healthchecks: exec-based probes, `starting → healthy/unhealthy` state machine, `service_healthy` gating (skeleton exists in `Supervisor`)
- [ ] Restart policies wired to exit events with docker-compatible backoff (logic done + tested; needs the watcher)
- [ ] Supervisor lives in whichever frontend ran `up` (v1); print the "supervision requires the Capsule agent" notice on CLI `-d`
- [ ] Drift reconcile on attach: observed (by labels) vs desired (ProjectStore) → report → optional auto-heal
- [ ] `.env` precedence edge cases; volumes/networks/builds/machines screens
- [ ] Dependency-graph visualization (SwiftUI Canvas)

## Phase 4 — Polish & public v0.1 (2 weeks) → `v0.1.0`

- [ ] Design pass to plan §6 spec (motion, typography, color tokens, translucency rules)
- [ ] Reduced-motion / reduced-transparency / increase-contrast audit; VoiceOver labels
- [ ] Crash/error reporting; honest compose-compatibility table in docs
- [ ] Docs site, README screenshots, demo recording (`compose plan` is the demo)
- [ ] Homebrew tap for the CLI; notarized dmg; Sparkle appcast groundwork
- [ ] Pick a license before the repo goes public
- [ ] Tag `v0.1.0`

## Later (v0.2+)

LaunchAgent supervisor (`capsuled`, SMAppService) with app/CLI as XPC clients ·
XPCClient runtime against apple/container Swift packages · profiles/multi-file/
`extends` · `develop.watch` file-sync rebuild · Keychain secrets · `container
machine` first-class UX · Sparkle auto-updates · plugin story.

## Top risks (watch actively)

1. **S1 fails (confirmed 2026-07-13)** — bare-hostname DNS doesn't work container-to-container on either network type → hosts-injection fallback (verified non-sudo) is the shipping mechanism for Phase 2; adds a per-restart reconciliation step to the supervisor. See [S1 spike](spikes/S1-dns-service-discovery.md).
2. **JSON gaps (resolved 2026-07-13, S2)** — no table-only commands found across `list`/`inspect`/`stats`/`system df`/`system status`/`volume`/`network`/`image` on 1.1.0; `inspect` family emits JSON unconditionally (no `--format` needed or accepted). No table-parser fallback required for anything probed so far — still pin the CLI version and re-check if a future surface (e.g. `container builder status`, S5) proves table-only. See [S2 spike](spikes/S2-json-coverage.md).
3. **Per-VM memory pressure** — many containers hold host memory → surface memory prominently in UI, "restart heavy containers" affordance.
