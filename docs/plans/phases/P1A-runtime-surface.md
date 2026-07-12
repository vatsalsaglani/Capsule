# P1A — Runtime surface (ContainerClient + EventBus)

The foundation package: the full runtime-access layer everything else consumes.

| | |
|---|---|
| Branch | `phase/p1a-runtime-surface` |
| Depends on | P0-S2 findings (don't block on them for the Contract PR); P0-S5 for cancellation hardening |
| Blocks | P1B (real data), P2A executor tasks, P3 probes — **unblocked by your early Contract PR, not your finish** |
| Owns | `Sources/ContainerClient/` (except `RuntimeUpdateChecker.swift` — that file is P1D's), `Sources/EventBus/`, `Tests/ContainerClientTests/`, new `Sources/ContainerClientTestSupport/` |

**Read first:** `AGENTS.md` (rules 2, 3, 7 + skill routing — this whole
package is `swift-concurrency-pro` territory); master plan §2.2, §3;
`docs/learnings/2026-07-12-runtime-cli-observations.md` (JSON casing, tolerant
decoding rationale); `docs/learnings/2026-07-12-swift-packaging-notes.md` §3
(the subprocess pattern you are extending).

## 1. Contract PR — ship this to `main` first, within days

Run the `design-an-interface` skill on the widened `ContainerRuntime` before
committing (protocol shape ripples into the future XPC client). Then land in
one small PR:

1. `ContainerRuntime` widened to cover these capabilities (exact signatures
   are yours to finalize; keep argument labels/spelling consistent with the
   existing five methods):
   - containers: `inspect(id) -> ContainerDetail`, `create(RunSpec) -> id`,
     `kill(id, signal)`, `logs(id, follow) -> AsyncThrowingStream<LogLine,_>`,
     `exec(id, argv, timeout) -> ExecResult` *(non-interactive; P3 health
     probes depend on this)*, `stats(ids) -> AsyncThrowingStream<StatsSample,_>`
   - images: `listImages`, `pullImage(reference) -> progress stream`,
     `deleteImage`, `tagImage`
   - volumes: `listVolumes`, `createVolume(name, labels)`, `deleteVolume`
   - networks: `listNetworks`, `createNetwork(name, labels, internal)`,
     `deleteNetwork`
   - system: `systemDF`, `systemStatus` (already present, formalize)
   - `RunSpec` must express everything P2A's §4.3 table needs: image, name,
     command/entrypoint, env, workdir, user, ports, mounts (bind/volume/tmpfs
     + readonly), network, platform, init, labels, dns/dns-search options,
     restart-irrelevant (supervisor's job).
2. `CLIProcessClient` conformance may be `throw RuntimeError.notImplemented`
   stubs beyond the existing five — signatures freeze now, bodies land below.
3. New library target `ContainerClientTestSupport` with `FakeContainerRuntime`:
   fully configurable canned responses + recorded calls, usable from other
   packages' tests (add the target + product to `Package.swift`).

## 2. Implementation (after the Contract PR merges)

- **S2 completion if the spike hasn't done it:** run a real container, capture
  `container list/inspect --format json`, tighten `ContainerSummary` (ports,
  labels — needed for compose grouping) and update the learnings note.
- `RunSpec → argv` builder, pure and golden-tested (this is where compose
  correctness lives; every flag mapping from master plan §4.3).
- Streaming: `logs --follow`, `pull`, `stats` via `FileHandle.bytes` →
  `AsyncThrowingStream`; drop-oldest ring buffer for UI consumers, full spool
  hook for ProjectStore (master plan §2.2). Cancellation tears down the child
  process (S5 contract: SIGTERM → grace → SIGKILL; fix the existing TODO in
  `Subprocess.swift`).
- `actor RuntimeGateway`: serialize mutating ops per resource id, concurrent
  reads (plan §2.2).
- **Poller → EventBus:** `actor Poller` diffing `listContainers(all: true)`
  every 1–2 s with idle backoff, synthesizing `RuntimeEvent`s
  (added/removed/stateChanged) onto `EventBus<RuntimeEvent>`. The API must let
  the XPC client replace it later without UI changes.

## Verification

- `swift build && swift test` — decode tests use verbatim S2-captured JSON.
- Manual matrix vs the real runtime: `swift run capsule ls`, then a scratch
  container: create/start/logs -f/stats/kill/delete via a small debug command
  or test script; confirm typed errors carry real stderr (stop the apiserver
  and check the failure mode reads well).
- `swift-concurrency-pro` review pass over the diff (actors, streams,
  cancellation) before merge.

## Out of scope

`RuntimeUpdateChecker.swift` (P1D owns it) · any App/ or CLI UI beyond debug
plumbing · compose semantics (P2A) · interactive PTY exec (P1C).
