# Phase plans — parallel execution across worktrees/agents

Each file in this folder is a **self-contained work package**: an agent (or
human) dropped into a fresh worktree with only that file + the repo should be
able to execute it end to end. The package granularity is chosen so packages
can run **concurrently in separate git worktrees** without merge collisions.

`docs/ROADMAP.md` stays the single status board (tick its checkboxes as
packages land); the master plan (`../apple-container-manager-plan.md`) stays
the *why*. These files are the *how, for one worktree at a time*.

## Running a package

```sh
# from the main checkout
git worktree add ../capsule-p1a -b phase/p1a-runtime-surface
cd ../capsule-p1a

# hand it to an agent (or start working yourself):
claude "Read AGENTS.md first, then execute docs/plans/phases/P1A-runtime-surface.md end to end. Stop and report if you need a decision."
```

Branch naming: `phase/<package-id>` (e.g. `phase/p0-s1-dns`, `phase/p2a-compose-engine`).
One package per worktree. Delete the worktree after merge.

## Dependency graph

```text
P0-S1 DNS ─────────────────────────┐
P0-S2 JSON ──► P1A runtime surface │
P0-S3 PTY ───► P1C terminal        │
P0-S5 build-cancel ─► P1A (late)   ▼
                                 P2A compose engine ──► P2B compose frontends
P1A contract PR (early merge) ───┘        │
P1A (full) ──► P1B app screens            ▼
P1D installer/onboarding (independent)   P3 supervision ──► P4 polish/release
```

**Wave 1 (start immediately, in parallel):** P0 spikes (S1 first — highest
risk), P1A (its *Contract PR* must merge within days), P1D, and P2A's
non-runtime tasks.
**Wave 2:** P1B, P1C, rest of P2A, then P2B.
**Wave 3 (sequential):** P3 after P2A+P1A merge; P4 last, single worktree.

## File-ownership matrix (the anti-conflict contract)

A package has **exclusive write access** to the paths it owns. Touching
another package's paths is a coordination failure — file an interface request
in your plan's notes instead and let the owner land it.

| Package | Owns (exclusive) |
|---|---|
| P0 spikes | `docs/spikes/*`, new `docs/learnings/*` notes |
| P1A | `Sources/ContainerClient/` (except `RuntimeUpdateChecker.swift`), `Sources/EventBus/`, `Tests/ContainerClientTests/`, new `Sources/ContainerClientTestSupport/` |
| P1B | `App/Capsule/` except `Terminal*`, `Onboarding/`, `Compose/` |
| P1C | `Sources/TerminalKit/`, `App/Capsule/Terminal*`, SwiftTerm dep in `Package.swift` |
| P1D | `Sources/ContainerClient/RuntimeUpdateChecker.swift`, new `Sources/RuntimeInstaller/`, `App/Capsule/Onboarding/` |
| P2A | `Sources/ComposeSpec/`, `Sources/ComposePlanner/`, `Sources/ComposeRuntime/`, `Sources/ProjectStore/`, their tests, `Fixtures/` |
| P2B | `Sources/CapsuleCLI/`, `App/Capsule/Compose/` |
| P3 | `Sources/Supervisor/` + agreed extension points in `ComposeRuntime` (runs after P2A merges) |
| P4 | cross-cutting; runs alone after everything else |

**Shared files — append-only, expect trivial conflicts, resolve by keeping
both sides:** `Package.swift` (target lists), `docs/ROADMAP.md` (checkboxes),
`AGENTS.md` References section, `docs/learnings/README.md` index.

**Read-only for everyone except P1A:** the `ContainerRuntime` protocol and its
DTOs. Consumers code against whatever the Contract PR ships; they never edit it.

## The Contract PR (how parallelism actually works)

P1A's **first deliverable** — merged to `main` before anything else it does —
widens `ContainerRuntime` to the full M1+M2 capability surface and ships
`FakeContainerRuntime` in a new `ContainerClientTestSupport` library target.
Real implementations may land later as throwing stubs; the *signatures* freeze
early. That unblocks P1B (ViewModels against fakes) and P2A's executor
(orchestration logic is tested entirely against the fake — master plan §7).
After the Contract PR merges, every other worktree rebases onto main.

## Definition of done (every package, no exceptions)

1. `swift build && swift test` green from the repo root; if you touched
   `App/`, the app builds (`xcodegen generate --spec App/project.yml
   --project App` + build, or the swiftc typecheck fallback in
   docs/learnings/2026-07-12-swift-packaging-notes.md §6).
2. AGENTS.md skill routing consulted for the areas you touched (e.g.
   `swift-concurrency-pro` review for ContainerClient/EventBus/Supervisor/
   ComposeRuntime changes; `swiftui-pro` pass for App/ changes).
3. **Learning loop executed:** non-obvious findings written to
   `docs/learnings/`, linked from AGENTS.md References and the learnings
   README index. Spikes also record decisions in `docs/spikes/README.md`.
4. Your checkboxes ticked in `docs/ROADMAP.md` (in the merge PR only).
5. No claims beyond reality in user-facing text (AGENTS rule 10) and no
   silent dropping of compose keys (rule 4).
6. Rebase onto latest `main` before merging; re-run the verification.
