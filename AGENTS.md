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

- [`docs/learnings/2026-07-12-runtime-cli-observations.md`](docs/learnings/2026-07-12-runtime-cli-observations.md) — `container` v1.1.0 ground truth: JSON casing/shape, `--format` values, empty-list behavior, version-line parsing; which model fields are still S2-unverified
- [`docs/learnings/2026-07-12-swift-packaging-notes.md`](docs/learnings/2026-07-12-swift-packaging-notes.md) — monorepo/XcodeGen layout, YAML Norway problem in compose decoding, Process-under-Swift-6 subprocess pattern, no-sandbox decision, app typecheck without Xcode
- [`docs/learnings/2026-07-13-container-dns-discovery.md`](docs/learnings/2026-07-13-container-dns-discovery.md) — bare-name DNS never resolves (either network type); `--dns-search`/`--dns-domain` plumb into `resolv.conf` but don't help; hosts injection works non-sudo (S1 decision); `system dns create` sudo wall; `system property` has no `set`; `inspect` resolved-IP lives under `status`, not `configuration`; one-time custom-network L3 reliability wedge under container churn

## Releases

GitHub is the release channel. Tags `v*` trigger `.github/workflows/release.yml`
(draft release + CLI tar.gz + checksums). Alphas `v0.0.x` from Phase 1, public
`v0.1.0` at Phase 4 with notarized dmg + Homebrew tap (see ROADMAP). Don't tag
or publish releases without being asked. License is TBD — must be chosen
before the repo goes public.
