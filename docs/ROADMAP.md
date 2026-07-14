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

Releases happen on GitHub: pushing `release/v<semver>` from an exact commit
that passed `main` CI publishes the corresponding version (a suffix makes it a
pre-release). The workflow stamps source and bundle metadata, creates GitHub's
required tag internally, attaches the CLI tarball, ad-hoc-signed app ZIP, DMG,
and checksums, then deploys the MkDocs site. Developer ID signing and
notarization remain Phase 4 distribution gates.

## Phase 0 — Spikes (1 week) — *de-risk before building*

Findings go to `docs/spikes/` (see the README there). S1 decides the service
discovery design (§4.4) and blocks Phase 2 planning details.

- [x] **S1 DNS/networks** *(decided 2026-07-13)* — bare-name DNS fails on both custom and default networks (`NXDOMAIN`); `--dns-search`/`--dns-domain` plumb into `resolv.conf` but don't help. Hosts injection verified non-sudo and ships as the default discovery mechanism; the search-domain primary path is sudo-gated (`system dns create`) and stays unverified pending a human. See [spike](spikes/S1-dns-service-discovery.md) and [learnings](learnings/2026-07-13-container-dns-discovery.md).
- [x] **S2 `--format json` coverage** *(fully verified 2026-07-13 with a populated runtime)* — populated `container list` shape captured; no table-only commands found (`system status`/`system df`/`stats` all support JSON; `inspect` family emits JSON unconditionally, no `--format` flag); `ContainerSummary` tightening list (ports, labels, networks, status) handed off to P1A. See [spike](spikes/S2-json-coverage.md) and [learnings](learnings/2026-07-12-runtime-cli-observations.md).
- [x] **S3 PTY/exec** *(decided 2026-07-13)* — SwiftTerm viable: TTY allocation, colors, resize, ctrl-c, and line editing all pass through `container exec -it`. TerminalKit owns the PTY directly (`posix_openpt`/`forkpty`) and drives SwiftTerm's `feed(byteArray:)`, not SwiftTerm's `LocalProcess`. Shell detection sh→bash→ash confirmed (alpine: sh/ash, no bash; debian: sh/bash/dash, no ash). MAJOR finding: the exec client ignores SIGTERM/SIGINT (unlike `build`) and SIGKILL can orphan a container-side process, so `PTYExecSession.terminate()` must shut down over the PTY bytes (ctrl-c then exit/EOF), not via process signals; container-stop cleans up the local client automatically (exit 137). See [spike](spikes/S3-pty-exec.md) and [learnings](learnings/2026-07-13-pty-exec-terminal.md).
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
- [x] Terminal: SwiftTerm over `container exec -it`, shell auto-detection, session tabs (add SwiftTerm dependency to TerminalKit) *(P1C — `PTYExecSession`/`ShellDetector`/`TerminalSessionManager` engine + `Tests/TerminalKitTests` (15 tests: two-session isolation, resize, cooperative-terminate incl. master-fd/pid teardown, SIGKILL fallback, shell-detection order/fallback/failure, manager open/close/switch/exited-state/watcher-lifecycle) all green headlessly against local `/bin/sh`, plus live-verified end to end against real `alpine`/`debian` containers (TERM propagation, resize, ctrl-c, two-container isolation, container-stop-while-attached → exit 137, no host/container orphans post-cleanup); App's `TerminalHostView`/`TerminalTabsView` (SwiftTerm `TerminalView`, not `LocalProcess`) compile-verified against the real SwiftTerm package + real CapsuleKit via a standalone SwiftPM probe (this environment's `xcodebuild` can't load its Simulator plugin, so that specific check substitutes for it) — **still open human gates:** live two-tab interactive typing into two containers in the actual running app, and an Xcode GUI build+run once `xcodebuild` works)*
- [x] Runtime install/update UX: onboarding screen when CLI missing → download latest release `.pkg` from GitHub, guide install; update banner when `RuntimeUpdateChecker` finds a newer release *(P1D — `RuntimeUpdateChecker.evaluate()` pure comparison + `Sources/RuntimeInstaller/RuntimeInstallerModel` (presence/update-status/download-and-handoff, never executes the `.pkg`, injectable runtime/fetch/download seams) + `capsule runtime status` CLI + `App/Capsule/Onboarding/{OnboardingView,UpdateBanner}` wired at the app root into `RootView`/`CapsuleApp`, all engine/store/compile-level complete against the real 1.1.0 runtime and the real GitHub API shape (verified live, see learnings) — **still open human gates:** an actual onboarding-screen click-through, a real `.pkg` download + running the installer, and the update banner appearing against a genuinely newer release)*
- [x] In-app CLI PATH setup: build the production `Sources/CapsuleCLI` frontend into `Capsule.app/Contents/Helpers/capsule`; System and runtime-missing onboarding surfaces safely inspect/install `/usr/local/bin/capsule`, preserve conflicts, confirm stale-link updates, and fall back to a copyable permission command without editing shell profiles or invoking sudo
- [x] Menu-bar extra: runtime up/down, running count, stop-all *(P1B B6/B7 — engine/store/compile-level complete, fed by the shared `RuntimeSession`/`MenuBarStore`; interactive click-through (Stop All, Open Capsule) is still an open human gate)*
- [ ] Feel prototype (plan §6.6): sidebar/list/inspector + one live-updating row + terminal, reviewed frame-by-frame — *sets the craft bar before UI build-out* *(P1B B2/B7 — the `#if DEBUG` `ScriptedDemoSession`/`FeelPrototypeDemoView` window compiles and drives the real Containers screen through genuine poll-driven state transitions; terminal now exists (P1C) but isn't wired into this prototype window yet; the frame-by-frame human review this line is named for hasn't happened — left unticked until that gate runs)*
- [x] Interactive onboarding/doctor screen in-app *(one progressive CapsuleKit snapshot stream now powers CLI doctor, onboarding, and System; typed remediation, exact 1.x gate, runtime re-check, local incident history/export, and post-install RuntimeSession replacement compile and test cleanly)*
- [x] Reproducible `v0.0.1` alpha artifacts ready *(one script/workflow builds and verifies the ad-hoc-signed app zip, unsigned/not-notarized dmg, CLI tar.gz, embedded CLI, and SHA-256 checksums)*
- [ ] Publish the first branch-driven `v0.0.1` alpha *(the workflow is ready; intentionally not triggered without an explicit release instruction)*

## Phase 2 — Compose core (3–4 weeks) → the launch demo

`capsule compose up/down/ps/logs/config/plan` for the §4.2 subset minus
health/restart; Compose screen in the app.

- [x] ComposeSpec: typed model for the supported subset, short/long syntax (ports, volumes), support report with fail-loud policy, interpolation utility, duration parsing
- [x] ComposePlanner: DAG from `depends_on`, cycle detection, deterministic layered plan, `compose plan`/`config` CLI
- [x] Wire interpolation + `.env`/`--env-file` into the parser (per-scalar, not raw text)
- [x] Implement S1 decision: service discovery via managed `/etc/hosts` injection before health gates and after starts; the fixed reconciliation runs as container-local UID 0 while user exec/probes retain the configured service identity
- [x] ComposeRuntime: execute steps for real (volume/network create, `run -d` with labels `capsule.project/service/index/config-hash`, local-image detection, pull/build progress)
- [x] Config-hash reconciliation: recreate only changed services, restart dependents in DAG order; `--force-recreate`, `--no-deps`
- [x] Parallelize independent plan branches (infrastructure barrier first; pulls/builds concurrent; starts respect DAG)
- [x] `compose up -d / down [--volumes] [--remove-orphans] / ps / logs [-f] / restart / stop / start / exec / build / pull`, plus `--quiet`, runtime-independent resolved `config --report`, layered `plan`, and bounded per-service terminal progress (responsive bars/icons/colors in a capable TTY; greppable plain fallback for pipes/CI)
- [x] ProjectStore: versioned `project.json`, `resolved-compose.json`, `state.json`, exact source/env/project-override replay, atomic writes, bounded rotated per-service log spools
- [x] Compose screen in app: ProjectStore + runtime-label discovery (including honest unavailable-source rows), project import/list, per-service status, bounded multiplexed logs, config/support report, up/down/restart, plan-before-apply viewer, surfaced progress/errors

Real-runtime acceptance passed on `container` 1.1.0 (2026-07-13): the
`basic-web-db.yaml` fixture reached PostgreSQL healthy, served nginx on
`localhost:8080`, injected service hosts, retained its named volume across a
plain down/up, and removed containers/network/volume to zero with
`down --volumes --remove-orphans`.

## Phase 3 — Supervision & fidelity (2–3 weeks)

- [x] Healthchecks: exec-based probes, `starting → healthy/unhealthy` state machine, `service_healthy` gating *(continuous observations persist attempt/output/time/container identity; relaunch shows stale state until an immediate live probe and never grants a second start period)*
- [x] Restart policies wired to exit events with Docker-compatible capped backoff *(absolute deadlines/attempts persist, restart storms are rate-limited, user stops win, and managed hosts refresh after a supervised restart; `container` 1.1.0 exposes no exit status, so exact `on-failure` is explicitly paused rather than guessed)*
- [x] Supervisor lives in whichever frontend ran `up` (v1); print the "supervision requires the Capsule agent" notice on CLI `-d` *(foreground CLI owns logs+supervision; one app-lifetime RuntimeSession task resumes every persisted project from the first authoritative poller snapshot)*
- [x] Drift reconcile on attach: observed (by labels) vs desired (ProjectStore) → report → optional auto-heal *(report-only is mutation-free; `--heal`/UI reconcile repair missing, changed, and unexpected-state services; orphans remain explicit-only deletion)*
- [x] `.env` precedence edge cases; volumes/networks/builds/machines screens *(all complete: direct Dockerfile builds with streamed/cancellable output, redacted durable history, builder lifecycle, plus thin-v1 machine create/list/inspect/start/stop/logs/delete in CapsuleKit, CLI, and app)*
- [x] Volume and Network lifecycle in CapsuleKit, CLI, and app: list/inspect, reverse references/attachments, create, protected delete, prune, ownership, confirmations, and built-in-network protection
- [x] Dependency-graph visualization (SwiftUI Canvas) *(deterministic start layers and dependency conditions come from CapsuleKit; native selectable/accessible nodes sit over the Canvas relationship layer)*

## Phase 4 — Polish & public v0.1 (2 weeks) → `v0.1.0`

- [ ] Design pass to plan §6 spec (motion, typography, color tokens, translucency rules) *(Compose, Containers, Images, Volumes, and Networks now share Graphite & Indigo tokens, adaptive card/list modes, hover-local actions, selected states, exact destructive previews, and solid log surfaces; System/onboarding/menu-bar and the human frame-by-frame gate remain)*
- [ ] Reduced-motion / reduced-transparency / increase-contrast audit; VoiceOver labels *(new collection surfaces use real labeled buttons, non-color state text, and reduce-motion-gated springs; full-app VoiceOver/contrast click-through remains a human gate)*
- [x] Crash/error reporting; honest compose-compatibility table in docs *(privacy choice: bounded structured local-only incidents, honest unclean-termination marker, explicit JSON export, no telemetry/uploader; CLI reference includes the enforced key/limitation table)*
- [x] MkDocs documentation site with Capsule branding, release guide, strict CI build, and post-release GitHub Pages deployment
- [ ] README screenshots and demo recording (`compose plan` is the demo)
- [ ] Homebrew tap for the CLI; notarized dmg; Sparkle appcast groundwork
- [x] Pick a license before the repo goes public *(Apache-2.0, matching apple/container)*
- [ ] Publish `v0.1.0` from `release/v0.1.0`

## Later (v0.2+)

LaunchAgent supervisor (`capsuled`, SMAppService) with app/CLI as XPC clients ·
XPCClient runtime against apple/container Swift packages · profiles/multi-file/
`extends` · `develop.watch` file-sync rebuild · Keychain secrets · advanced
`container machine` configuration/interactive-exec UX · Sparkle auto-updates · plugin story.

## Top risks (watch actively)

1. **S1 fails (confirmed 2026-07-13)** — bare-hostname DNS doesn't work container-to-container on either network type → hosts-injection fallback (verified non-sudo) is the shipping mechanism for Phase 2; adds a per-restart reconciliation step to the supervisor. See [S1 spike](spikes/S1-dns-service-discovery.md).
2. **JSON gaps (resolved 2026-07-14, S2 + Builds/Machines)** — no table-only commands found across `list`/`inspect`/`stats`/`system df`/`system status`/`volume`/`network`/`image`/`builder status`/`machine list` on 1.1.0; `inspect` family emits JSON unconditionally (no `--format` needed or accepted). No table-parser fallback is required for anything probed so far; pin the CLI version and re-check new surfaces on upgrade. See [S2 spike](spikes/S2-json-coverage.md) and [builder/machine learning](learnings/2026-07-14-builder-machine-runtime-contract.md).
3. **Per-VM memory pressure** — many containers hold host memory → aggregate and per-container memory are now surfaced prominently while collection screens are visible; the dedicated "restart heavy containers" affordance remains.
