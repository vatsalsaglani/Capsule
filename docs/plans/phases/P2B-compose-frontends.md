# P2B — Compose frontends (CLI + Compose screen)

Thin frontends over P2A's engine. This package is the launch demo.

| | |
|---|---|
| Branch | `phase/p2b-compose-frontends` |
| Depends on | P2A engine API (start once its `ComposeRuntime` public surface stabilizes — coordinate, don't guess); P1A logs streaming for `logs -f` |
| Blocks | P4 demo material |
| Owns | `Sources/CapsuleCLI/`, `App/Capsule/Compose/` |

**Read first:** `AGENTS.md` (rules 1, 10); master plan §4.8 (CLI surface +
docker-compose muscle-memory rule), §6.2 (Compose project layout in the app);
skills: `swiftui-expert-skill` for the screen, `swiftui-pro` before merge.
The existing `ComposeCommands.swift` stubs show the argument conventions.

## Deliverables

1. **CLI, replacing the M2 stubs:** `up [-d] [--build] [--force-recreate]
   [--no-deps] [service…]`, `down [--volumes] [--remove-orphans]`, `ps`,
   `logs [-f] [service…]`, `restart|stop|start`, `build`, `pull`,
   `exec <service> <cmd…>`, `config --report` (prints the S1 name-resolution
   explanation P2A provides + the support report — never hide it), `plan`
   (renders P2A's layered plan with the parallel groups visible). Exit codes
   mirror `docker compose` where semantics match; `-d` prints the supervision
   notice (master plan §4.6) verbatim.
2. **Progress rendering:** `up` streams `ComposeEvent`s as per-service lines
   (pull progress, create, start, healthy-wait) — plain, greppable output;
   `--quiet` for scripts.
3. **`capsule ls` project grouping:** group by `capsule.project` label,
   ungrouped containers last.
4. **Compose screen (`App/Capsule/Compose/`):** project list (from
   ProjectStore + label discovery); per-service rows with state dots and
   ports; Up/Down/Restart/Plan/Config actions; project logs tab (multiplexed,
   service-colored prefixes, solid dark surface); **plan viewer** — render the
   step layers before confirming Up (the demo moment; design it with
   `apple-design` restraint, no gratuitous animation).
5. Drag-and-drop a `compose.yaml` onto the window/dock → opens as a project
   (master plan §6.1 familiarity).
6. ViewModels logic-free; all formatting/grouping decisions live in CapsuleKit
   (add small helpers to P2A's modules via interface request if needed —
   don't inline business rules).

## Verification

End-to-end on this machine: `swift run capsule compose up -f
Fixtures/compose/basic-web-db.yaml` → nginx serves on :8080, `ps` shows both
services with health, `logs -f` streams, `down --volumes` cleans to zero
(verify with `container list --all` + `container volume ls`). Same flow from
the app UI. `capsule compose plan` output pasted into the PR description
(it doubles as the demo script). App builds; `swiftui-pro` pass.

## Out of scope

Engine semantics (file interface requests with P2A) · health/restart states in
`ps` output beyond what P2A exposes pre-P3 · dependency-graph Canvas viz (P3).
