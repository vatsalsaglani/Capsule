# Learnings

**The standing rule (from AGENTS.md):** whenever implementation work surfaces a
non-obvious fact — runtime CLI behavior, JSON shapes, macOS API constraints,
Swift concurrency traps, packaging quirks — it gets captured here *in the same
session*, and the note is linked from the **References** section of AGENTS.md.
Knowledge that only lives in a commit message or a chat transcript is lost.

## Format

One topic per file, named `YYYY-MM-DD-<topic>.md` (date = when first written;
update in place afterwards, don't fork new dated copies of the same topic).

```markdown
# <Topic>

**Context:** what we were doing when this surfaced.
**Finding:** the fact, precisely — include exact commands, versions, output.
**Consequence:** what Capsule does differently because of it.
```

Keep findings falsifiable and versioned ("v1.1.0 emits X") so they can be
re-verified when the runtime updates. When a finding is invalidated, edit the
note and say so — don't delete history silently.

## Index

- [2026-07-12 — runtime CLI observations](2026-07-12-runtime-cli-observations.md)
- [2026-07-12 — Swift/packaging notes](2026-07-12-swift-packaging-notes.md) — includes the app `swiftc` fallback for local Xcode plug-in failures
- [2026-07-13 — container DNS / service discovery](2026-07-13-container-dns-discovery.md)
- [2026-07-13 — P1A Contract PR: `ContainerRuntime` design decisions](2026-07-13-container-runtime-contract.md)
- [2026-07-13 — `container build` cancellation semantics](2026-07-13-build-cancellation.md)
- [2026-07-13 — P1A implementation: CLI argv facts + a Subprocess cancellation edge case](2026-07-13-p1a-implementation-notes.md)
- [2026-07-13 — stats polling cost](2026-07-13-stats-polling-cost.md)
- [2026-07-13 — `cpuUsageUsec` semantics: cumulative, not a rate](2026-07-13-cpu-usage-usec-semantics.md)
- [2026-07-13 — swift-testing: `@Test` function names must be unique per target, not per file](2026-07-13-swift-testing-name-collisions.md)
- [2026-07-13 — `container exec -it` PTY behavior + Terminal (P1C) integration path](2026-07-13-pty-exec-terminal.md)
- [2026-07-13 — PTY spawn (`PTYExecSession`) vs. the `Subprocess`/`SubprocessLineStream` pattern](2026-07-13-pty-spawn-vs-subprocess.md) — includes released fd/PID identity reuse in parallel teardown tests
- [2026-07-13 — runtime installer: apple/container GitHub release shape (P1D)](2026-07-13-runtime-installer-release-assets.md)
- [2026-07-13 — `ContainerBinaryLocator`'s override env var wasn't validated (P1D)](2026-07-13-binary-locator-override-validation.md)
- [2026-07-13 — container inspect does not expose process exit status](2026-07-13-container-exit-status-gap.md)
- [2026-07-13 — volume/network prune has no structured output](2026-07-13-resource-prune-contract.md)
- [2026-07-13 — Compose live release blockers on container 1.1.0](2026-07-13-compose-live-release-blockers.md) — infrastructure barrier, exact-image pull skip, nonempty resource labels, and pre-health hosts scope
- [2026-07-13 — ProjectStore path containment needs lexical and symlink-aware checks](2026-07-13-project-store-path-safety.md)
- [2026-07-13 — Apple container volume roots contain `lost+found`; PostgreSQL needs a `PGDATA` subdirectory](2026-07-13-postgres-volume-lost-found.md)
- [2026-07-13 — bundle the CLI in `Contents/Helpers`; safely manage `/usr/local/bin/capsule`](2026-07-13-bundled-cli-path-install.md)
- [2026-07-13 — Compose pull progress grammar and bounded terminal rendering](2026-07-13-compose-pull-progress.md)
- [2026-07-13 — Compose managed-hosts exec identity](2026-07-13-compose-hosts-exec-identity.md) — root-only maintenance without changing user exec/probe identity
- [2026-07-13 — replaceable tasks need explicit lifetime ownership](2026-07-13-replaceable-stream-task-generation.md) — cancellation needs generation gating, and SwiftUI tasks tied to replaceable inputs need explicit view/task identity
- [2026-07-13 — container registries do not standardize image logos](2026-07-13-container-image-logo-metadata.md) — use an optional provider and disk cache for public official-image logos; keep the local blue fallback
- [2026-07-14 — frontend supervision needs durable checkpoints](2026-07-14-frontend-supervision-checkpointing.md) — persist intent, health, deadlines, and refresh hosts after supervised restarts
- [2026-07-14 — local diagnostics lifecycle and privacy boundary](2026-07-14-local-diagnostics-lifecycle.md) — delayed AppKit termination, honest unclean markers, and structured local-only exports
- [2026-07-14 — Foundation `Process` stream exit registration under concurrent tests](2026-07-14-foundation-process-stream-exit.md) — store termination-handler results before awaiting, avoid signaling naturally finished PIDs, and serialize black-box process fixtures instead of widening production deadlines
- [2026-07-14 — builder and machine runtime contracts](2026-07-14-builder-machine-runtime-contract.md) — structured empty states, semantic machine start via `run`, JSON shapes, progress redaction, and actor-reentrant lifecycle serialization
- [2026-07-14 — branch-driven releases and GitHub Pages](2026-07-14-branch-release-pages.md) — exact-SHA CI gating, workflow-owned tags, prerelease-safe bundle versions, and released-source docs deployment
