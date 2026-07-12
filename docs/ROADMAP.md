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
- [x] **S2 `--format json` coverage** *(seeded 2026-07-12)* — v1.1.0 confirmed; lowerCamelCase nested-`configuration` shape verified for `image list`; `container list` shape still needs a populated runtime. See [learnings](learnings/2026-07-12-runtime-cli-observations.md).
- [ ] **S3 PTY/exec** — SwiftTerm + `container exec -it` interactive quality (resize, colors, ctrl-c).
- [ ] **S4 stats streaming** — `stats` output format, cost of polling 10 containers.
- [ ] **S5 build streaming + cancel** — SIGINT semantics of `container build`; wire SIGKILL escalation into `Subprocess`.

## Phase 1 — Runtime manager MVP (3–4 weeks) → `v0.0.x` alpha

Manage the full container/image lifecycle without touching Terminal; app
survives runtime restarts and CLI absence gracefully.

- [x] Repo scaffold: CapsuleKit SPM monorepo, `ContainerRuntime` protocol, `CLIProcessClient` (list/start/stop/delete/version), version gate, `Subprocess` with timeout+cancellation
- [x] `capsule doctor` (binary, version, apiserver status, GitHub update check)
- [x] `capsule ls`; app skeleton: sidebar, live-polling Containers screen, menu-bar extra stub
- [ ] Poller → EventBus → synthesized `RuntimeEvent`s (replace the ViewModel's direct polling loop)
- [ ] Containers screen: inspect detail, logs (follow), stats sparkline, `container cp`, open-in-browser from port mappings
- [ ] Images screen: list, pull with progress, tag, push, delete, prune, registry login
- [ ] System screen: runtime status/versions, `system df`, start/stop runtime, log viewer
- [ ] Terminal: SwiftTerm over `container exec -it`, shell auto-detection, session tabs (add SwiftTerm dependency to TerminalKit)
- [ ] Runtime install/update UX: onboarding screen when CLI missing → download latest release `.pkg` from GitHub, guide install; update banner when `RuntimeUpdateChecker` finds a newer release
- [ ] Menu-bar extra: runtime up/down, running count, stop-all
- [ ] Feel prototype (plan §6.6): sidebar/list/inspector + one live-updating row + terminal, reviewed frame-by-frame — *sets the craft bar before UI build-out*
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
2. **JSON gaps** — some commands lack `--format json` → pin CLI version, contribute upstream PRs, keep table-parser fallback behind a version check.
3. **Per-VM memory pressure** — many containers hold host memory → surface memory prominently in UI, "restart heavy containers" affordance.
