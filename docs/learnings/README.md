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
- [2026-07-12 — Swift/packaging notes](2026-07-12-swift-packaging-notes.md)
- [2026-07-13 — container DNS / service discovery](2026-07-13-container-dns-discovery.md)
- [2026-07-13 — P1A Contract PR: `ContainerRuntime` design decisions](2026-07-13-container-runtime-contract.md)
- [2026-07-13 — `container build` cancellation semantics](2026-07-13-build-cancellation.md)
- [2026-07-13 — P1A implementation: CLI argv facts + a Subprocess cancellation edge case](2026-07-13-p1a-implementation-notes.md)
- [2026-07-13 — stats polling cost](2026-07-13-stats-polling-cost.md)
