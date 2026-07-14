# AGENTS.md — Capsule

Capsule is a native macOS container manager (SwiftUI) + `capsule` CLI + a
Compose-style orchestrator for Apple's `container` runtime. App and CLI are
thin frontends over one engine, **CapsuleKit** (the SPM targets in `Sources/`).

**Sources of truth — read in this order before non-trivial work:**
1. `docs/plans/apple-container-manager-plan.md` — product + architecture (the *why*; section refs like §4.4 in code comments point here)
2. `docs/ROADMAP.md` — phase plan, what's done, what's next (keep checkboxes current)
   - executing a phase? use the per-worktree work packages in `docs/plans/phases/` (ownership matrix + merge order in its README; each package file is self-contained for one agent)
3. **References** below — hard-won facts; never re-derive what a learning note already answers
4. `docs/spikes/README.md` — open experiments and recorded decisions

## Architecture rules (non-negotiable)

1. **App/ and CapsuleCLI/ contain zero business logic.** Every feature must be drivable from a unit test against CapsuleKit. If a ViewModel or command grows logic, move it into a module.
2. **All runtime access goes through the `ContainerRuntime` protocol** (`Sources/ContainerClient`). Never call the `container` binary directly from views, view models, or commands. The CLI subprocess client is the MVP implementation; an XPC client joins later behind the same protocol.
3. **Subprocess discipline:** argv arrays via `Subprocess.run` — never interpolate into a shell string. Prefer `--format json`. Timeouts and cancellation on every call. Map failures to typed errors (`RuntimeError`) carrying the real stderr.
4. **Fail loud on compose input:** every key we don't act on goes through `SupportReport` (warning/fatal). Silent dropping of user config is a bug, always.
5. **Labels are the project-tracking backbone:** `capsule.project`, `capsule.service`, `capsule.index`, `capsule.config-hash` on every resource the compose engine creates. Deterministic names: `<project>-<service>-<n>`, `<project>_default`, `<project>_<volume>`.
6. **Supervisor stays agent-ready:** no UI imports, fully serializable state — it moves into a LaunchAgent (`capsuled`) in v1.1 unchanged.
7. **Version-gate the runtime:** detect the CLI version at startup; Capsule targets `container` 1.x (developed against 1.1.x). Runtime install/updates come from apple/container GitHub releases via `RuntimeUpdateChecker` — never silently install; guide the user.
8. **On-disk state is versioned JSON with atomic writes** (`ProjectStore`). Bump `schemaVersion` and migrate explicitly on breaking changes. No SwiftData/SQLite unless log indexing forces it.
9. **Design rules:** accent color (indigo) never means state — container state is always systemGreen/Orange/Red/Gray. Motion house style is critically damped springs. Full spec: plan §6.
10. **Honest scoping in user-facing text:** we support a documented compose subset; never claim more.

## Build & verify

```sh
swift build && swift test          # engine + CLI (from repo root)
swift run capsule doctor           # end-to-end sanity vs the real runtime
swift run capsule compose plan -f Fixtures/compose/basic-web-db.yaml
xcodegen generate --spec App/project.yml --project App   # app project (generated, git-ignored)
# no xcodegen? typecheck app sources: see docs/learnings/2026-07-12-swift-packaging-notes.md §6
```

Swift 6 language mode with strict concurrency everywhere. Tests use
swift-testing (`import Testing`, `@Test`, `#expect`). New modules = new targets
in the root `Package.swift`. Never hand-edit `App/Capsule.xcodeproj`; edit
`App/project.yml` and regenerate.

## Skill routing (`.agents/skills/`)

Consult the matching skill **before** writing code in its area, not as cleanup.

| When you are… | Use skill | Notes |
|---|---|---|
| Writing or refactoring any SwiftUI in `App/` | `swiftui-expert-skill` | check `references/latest-apis.md` first; state management, identity, performance |
| Reviewing SwiftUI before merge | `swiftui-pro` | checklist-style review pass; run after significant App/ changes |
| Touching actors, AsyncStream, Sendable, cancellation — i.e. `ContainerClient`, `EventBus`, `Supervisor`, `ComposeRuntime`, `Subprocess` | `swift-concurrency-pro` | review every change in these modules with it; the hotspots/bug-patterns refs catch real traps |
| Designing/changing a CapsuleKit public API (e.g. widening `ContainerRuntime`, new module surface) | `design-an-interface` | "design it twice" — generate competing shapes before committing; protocol changes ripple into the future XPC client |
| Building interaction/motion: feel prototype, inspector transitions, state-dot animation, drag/gesture work | `apple-design` | plan §6 was written against this skill; translate its web guidance to native SwiftUI springs |
| Auditing existing app motion for quality | `improve-animations` | produces prioritized audit + plans; read-only |
| Needing the exact name of a motion effect | `animation-vocabulary` | vocabulary lookup only |
| Adding CPU/mem sparklines, stats timelines, resource charts (Containers screen, System screen) | `swift-charts` | includes selection/scrolling/annotation patterns |
| Explicitly adopting Liquid Glass surfaces | `swiftui-liquid-glass` | only when deliberately adopting; plan §6 materials rules still win (never stack light translucent surfaces; logs/terminal stay solid) |
| Working with SwiftData | `swiftdata-pro` | **not currently applicable** — ProjectStore is JSON-on-disk by design (rule 8); use only if that decision is ever revisited |

## Standing rule: the learning loop

This project's compounding advantage is documented nuance. **After any task
that surfaces a non-obvious fact** — runtime CLI behavior, JSON shape drift,
macOS API constraint, concurrency trap, packaging quirk, design decision with
a non-obvious reason:

1. Write or update a note in `docs/learnings/` (format in its README; exact commands, versions, output).
2. Add or refresh the one-line entry in **References** below *and* in the learnings README index.
3. Spike outcomes additionally get their decision recorded in `docs/spikes/README.md` and reflected in `docs/ROADMAP.md`.

Symmetrically, **before starting work, scan References** for related notes and
read the relevant ones. Never let this file reference a note that doesn't
exist, and never leave a session's discoveries undocumented. If a note turns
out to be wrong, correct it in place and say what changed.

## References — learned nuances (grows over time)

- [`docs/learnings/2026-07-12-runtime-cli-observations.md`](docs/learnings/2026-07-12-runtime-cli-observations.md) — `container` v1.1.0 ground truth: JSON casing/shape, `--format` values (incl. which commands lack it — none found so far), empty-list behavior, version-line parsing; populated `container list`/`inspect` shape verified (S2, 2026-07-13) with the `ContainerSummary` tightening list P1A applies
- [`docs/learnings/2026-07-12-swift-packaging-notes.md`](docs/learnings/2026-07-12-swift-packaging-notes.md) — monorepo/XcodeGen layout, YAML Norway problem in compose decoding, Process-under-Swift-6 subprocess pattern, no-sandbox decision, app typecheck without Xcode (including local Xcode plug-in/framework mismatch fallback)
- [`docs/learnings/2026-07-13-container-dns-discovery.md`](docs/learnings/2026-07-13-container-dns-discovery.md) — bare-name DNS never resolves (either network type); `--dns-search`/`--dns-domain` plumb into `resolv.conf` but don't help; hosts injection works non-sudo (S1 decision); `system dns create` sudo wall; `system property` has no `set`; `inspect` resolved-IP lives under `status`, not `configuration`; one-time custom-network L3 reliability wedge under container churn
- [`docs/learnings/2026-07-13-container-runtime-contract.md`](docs/learnings/2026-07-13-container-runtime-contract.md) — P1A Contract PR design-an-interface rationale: streaming methods return concrete `AsyncThrowingStream` (XPC-load-bearing, do not revise casually — see the note before touching `logs`/`stats`/`pullImage`'s return type); `RunSpec` Hashable+Codable is load-bearing for §4.5 config-hash reconciliation; `stats` is tick-batched (`[StatsSample]` per element, not per-sample); flat `RuntimeError` + `.notImplemented`; `FakeContainerRuntime` never simulates state transitions
- [`docs/learnings/2026-07-13-build-cancellation.md`](docs/learnings/2026-07-13-build-cancellation.md) — `container build` SIGINT/SIGTERM both exit cleanly in <1s with builder left consistent; even SIGKILL of the CLI orphans nothing in the builder VM (verified via `container exec buildkit ps aux`); builder lifecycle states (`builder is not running` vs `stopped` vs `running`, `delete` vs `stop`); `--progress plain` is line-oriented/ANSI-free and safe for `FileHandle.bytes` streaming; recommended general `Subprocess` contract: SIGTERM → 5s grace → SIGKILL, applied to all spawned children, not build-specific
- [`docs/learnings/2026-07-13-p1a-implementation-notes.md`](docs/learnings/2026-07-13-p1a-implementation-notes.md) — P1A implementation argv facts (`--network` repeatable, `-v :ro` works for bind+volume, populated `configuration.mounts[]` shape incl. bind's `virtiofs` type key, `exec` propagates inner exit code exactly, stdout/stderr fd split varies per command, `stats --format json` streaming is a dead end — corrects finding #9 above — `create` has no `--progress` flag); a `Subprocess` cancellation edge case (a killed direct child can still leave pipes open via an orphaned grandchild that inherited the fds — `Subprocess.run` has a bounded force-resolve fallback for this, `SubprocessLineStream` deliberately does not, since real `container` invocations are single-process)
- [`docs/learnings/2026-07-13-stats-polling-cost.md`](docs/learnings/2026-07-13-stats-polling-cost.md) — `stats --no-stream --format json` has a fixed ~2.2s wall-clock latency floor independent of N (1/5/10 containers all ~2.2-2.4s), dominated by round-trip wait not CPU (apiserver 0.0% CPU under sustained polling); real `CLIProcessClient.stats(ids:)` update cadence at the 2s default is ≈4.2s (call+sleep, not a flat 2s); P1B should pause the poll when the sparkline UI isn't visible and reuse `stats(ids:)` directly (no dedicated actor); zsh does not word-split unquoted variables the way bash does (`${=VAR}` needed for variadic `container` invocations from a variable)
- [`docs/learnings/2026-07-13-cpu-usage-usec-semantics.md`](docs/learnings/2026-07-13-cpu-usage-usec-semantics.md) — `StatsSample.cpuUsageMicroseconds` confirmed cumulative (cgroup-style monotonic counter since container start), not a pre-computed rate — verified live against a CPU-pegging scratch container (three `stats` ticks ~7s apart, delta ≈ wall-elapsed × 1 core busy); CPU% must be derived as a delta over wall-clock elapsed time between ticks, not the nominal `statsInterval`
- [`docs/learnings/2026-07-13-swift-testing-name-collisions.md`](docs/learnings/2026-07-13-swift-testing-name-collisions.md) — `@Test func` names must be unique across an entire test *target*, not just per file — the macro's generated registration type collides across files with a cryptic "invalid redeclaration" error pointing at the macro expansion, not your code; grep `Tests/` for the name before reusing a test-name pattern from another file
- [`docs/learnings/2026-07-13-pty-exec-terminal.md`](docs/learnings/2026-07-13-pty-exec-terminal.md) — `container exec -it` 1.1.0 PTY ground truth: TTY/color/resize/ctrl-c/line-editing all pass, `-i`+`-t` both required with a real PTY on stdio; shell inventory per image (alpine sh/ash no bash, debian sh/bash/dash no ash); MAJOR — the exec client ignores SIGTERM/SIGINT (unlike `build`) and SIGKILL can orphan a container-side process, so P1C's `PTYExecSession.terminate()` must shut down over the PTY bytes, not process signals; container-stop cleans up the local client automatically (exit 137)
- [`docs/learnings/2026-07-13-pty-spawn-vs-subprocess.md`](docs/learnings/2026-07-13-pty-spawn-vs-subprocess.md) — P1C `PTYExecSession` vs. the `Subprocess` pattern: no `Process` object at all (zero new `@unchecked Sendable`), `waitpid(WNOHANG)`-polled reap instead of blocking `waitUntilExit()`, `forkpty`/`TIOCSWINSZ` fully visible via plain `import Darwin` on this SDK; MAJOR — forked children inherit *every* fd above 2 (not just 0/1/2), which surfaced as ~50%-flaky full-suite runs via `swiftpm-testing-helper`'s own pipes leaking into an orphaned test-fixture grandchild — fixed by closing all inherited fds above 2 in the child before `execv`; released fd/PID numbers are not stable post-teardown identities in parallel tests, so assert actor-recorded syscall outcomes; `withTaskGroup`-based cancellation races don't work against a `CheckedContinuation`-suspended child task (it silently waits for real completion instead of the timeout) — use a dedicated actor-owned continuation instead; Swift 6.2 requires explicit `@MainActor` conformance isolation (`NSObject, @MainActor TerminalViewDelegate`) for a `nonisolated` SwiftTerm protocol; `TERM=xterm-256color` propagation confirmed live
- [`docs/learnings/2026-07-13-runtime-installer-release-assets.md`](docs/learnings/2026-07-13-runtime-installer-release-assets.md) — apple/container's latest-release JSON verified live (P1D): plain `x.y.z` tag, **two** `.pkg` assets at once (signed + unsigned) — `installerPackage` must prefer the signed one, not just the first `.pkg` in asset order
- [`docs/learnings/2026-07-13-binary-locator-override-validation.md`](docs/learnings/2026-07-13-binary-locator-override-validation.md) — `ContainerBinaryLocator`'s `$CAPSULE_CONTAINER_BIN` override was trusted unvalidated (unlike its other two candidates), so a nonexistent override path leaked raw subprocess errors through `doctor`/`ls`/`runtime status` instead of clean `binaryNotFound` guidance; fixed in P1D
- [`docs/learnings/2026-07-13-postgres-volume-lost-found.md`](docs/learnings/2026-07-13-postgres-volume-lost-found.md) — Apple `container` 1.1.0 named volumes expose an ext4-root `lost+found`; PostgreSQL 16 rejects the mount root as `PGDATA`, so Compose fixtures mount the volume at `/var/lib/postgresql/data` but set `PGDATA` to a child directory
- [`docs/learnings/2026-07-13-compose-live-release-blockers.md`](docs/learnings/2026-07-13-compose-live-release-blockers.md) — live P2/P3 gate: infrastructure must finish before pulls/builds on runtime 1.1, exact installed image references skip pulls, project resources need nonempty deterministic `capsule.service` labels, and pre-health hosts injection may inspect only guaranteed-started peers
- [`docs/learnings/2026-07-13-container-exit-status-gap.md`](docs/learnings/2026-07-13-container-exit-status-gap.md) — `container` 1.1.0 inspect/list JSON reports only `stopped` for a process that exited 7; no exit code/signal/reason is exposed, so CLI-polling cannot honestly implement exact `restart: on-failure` semantics
- [`docs/learnings/2026-07-13-resource-prune-contract.md`](docs/learnings/2026-07-13-resource-prune-contract.md) — `container` 1.1.0 volume/network prune expose no JSON/`--format`; typed removed names must be derived from before/after JSON lists while raw output remains notices
- [`docs/learnings/2026-07-13-project-store-path-safety.md`](docs/learnings/2026-07-13-project-store-path-safety.md) — ProjectStore paths require both lexical containment and a second symlink-resolved containment check; standardization alone does not stop an existing project-directory symlink from redirecting writes outside `projects/`
- [`docs/learnings/2026-07-14-frontend-supervision-checkpointing.md`](docs/learnings/2026-07-14-frontend-supervision-checkpointing.md) — frontend residency needs durable intent/health/restart-deadline checkpoints; restored health is stale until a live probe, start-period is not re-granted, and supervised restarts refresh managed hosts
- [`docs/learnings/2026-07-14-local-diagnostics-lifecycle.md`](docs/learnings/2026-07-14-local-diagnostics-lifecycle.md) — async cleanup from `applicationWillTerminate` is unreliable; use delayed AppKit termination, label leftover markers as unclean (not proven crashes), and persist only bounded structured local incidents with no uploader
- [`docs/learnings/2026-07-14-foundation-process-stream-exit.md`](docs/learnings/2026-07-14-foundation-process-stream-exit.md) — under concurrent Swift tests, an instant scripted child can exhaust a production timeout and a post-EOF `Process.waitUntilExit()` can wedge after the child is gone; bridge a preinstalled termination handler through a stored async coordinator, never signal on natural stream finish, gate delayed PID escalation on recorded exit, and serialize the black-box subprocess suite rather than widening production deadlines
- [`docs/learnings/2026-07-14-branch-release-pages.md`](docs/learnings/2026-07-14-branch-release-pages.md) — branch-only release UX still requires a workflow-managed Git tag; gate the exact `main` CI SHA, keep full prerelease SemVer outside `CFBundleShortVersionString`, and tag a deterministic version-only child commit so source archives match binaries
- [`docs/learnings/2026-07-13-bundled-cli-path-install.md`](docs/learnings/2026-07-13-bundled-cli-path-install.md) — `Capsule`/`capsule` case-collide in `Contents/MacOS`; build the real CLI as a nested Xcode target in `Contents/Helpers`, and manage only a validated `/usr/local/bin/capsule` symlink without editing shell profiles or invoking sudo
- [`docs/learnings/2026-07-13-compose-pull-progress.md`](docs/learnings/2026-07-13-compose-pull-progress.md) — `container pull`'s anchored stage/phase/percent/blob/bytes/rate/elapsed grammar (including inherited units), plus Capsule's TTY capability gate, bounded plain fallback, stable service colors, sanitization, resize, and cleanup rules
- [`docs/learnings/2026-07-13-compose-hosts-exec-identity.md`](docs/learnings/2026-07-13-compose-hosts-exec-identity.md) — `container exec --user 0` must precede the container ID; only Capsule's fixed managed-hosts reconciliation elevates to container-local UID 0, while user exec, health probes, shell detection, and PTY sessions preserve the service/image identity
- [`docs/learnings/2026-07-13-replaceable-stream-task-generation.md`](docs/learnings/2026-07-13-replaceable-stream-task-generation.md) — cancelling an actor-owned stream task does not prevent its deferred cleanup/error path from overwriting a replacement; gate writes with a generation token; SwiftUI `.task` follows view identity, so replaceable inputs need an explicit `.id`/`.task(id:)` lifecycle boundary
- [`docs/learnings/2026-07-13-container-image-logo-metadata.md`](docs/learnings/2026-07-13-container-image-logo-metadata.md) — OCI/registry metadata has no portable image-logo field; resolve public Docker Official Image logos through an optional provider, cache by tag-free repository identity (including negative results), never leak private references, and preserve Capsule's blue fallback
- [`docs/learnings/2026-07-14-builder-machine-runtime-contract.md`](docs/learnings/2026-07-14-builder-machine-runtime-contract.md) — `container` 1.1.0 builder/machine JSON and lifecycle ground truth: empty arrays are typed absence, machine start is `run --root --name ID true`, unknown states stay visible, build progress redacts argument values, and actor reentrancy requires reserving builds before history awaits

## Releases

GitHub is the release channel. Pushing `release/v<semver>` triggers
`.github/workflows/release.yml` only when that exact commit passed `main` CI;
the workflow stamps versions, creates GitHub's required tag, publishes assets,
and deploys the docs. A prerelease suffix marks the GitHub release as a
pre-release. Alphas are `v0.0.x`; public `v0.1.0` still requires Phase 4's
notarized dmg + Homebrew tap (see ROADMAP). Don't create a release branch,
tag, or publication without being asked. Capsule is Apache-2.0 licensed,
matching apple/container.
