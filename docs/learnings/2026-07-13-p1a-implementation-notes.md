# P1A implementation: CLI argv facts + a Subprocess cancellation edge case

**Context:** P1A implementation PR — building real bodies behind the frozen
Contract (`d7aac9b`): `RunSpecArgvBuilder`, `SubprocessLineStream`,
`Subprocess`'s SIGTERM→grace→SIGKILL escalation, `RuntimeGateway`,
`RuntimePoller`. This note captures the live-probed facts the implementation
was built against, plus a concurrency edge case discovered while writing the
escalation test.

## Findings — live `container` 1.1.0 probes (grounding the argv builder)

1. **`--network` is repeatable, no constraint observed.** `RunSpec.networks:
   [String]` maps to one `--network <name>` per entry, in array order —
   attaching a container to multiple networks at create time works cleanly.
2. **`-v source:target:ro` works for both bind mounts and named volumes.**
   `container inspect` on the result shows `options: ["ro"]` in both cases.
   The Contract PR's original argv table guessed a separate `--mount
   type=bind|volume,…,readonly` form for the read-only case — that guess is
   wrong-but-harmless (the runtime does accept `--mount …,readonly` as an
   *equivalent*), and `RunSpec.createArguments` now uses the simpler uniform
   `-v src:tgt[:ro]` / `-v name:tgt[:ro]` form for every mount, read-only or
   not. See `RunSpec.swift`'s doc comment for the corrected table.
3. **Populated `configuration.mounts[]` shape** (the Contract PR only ever
   observed an empty array): `{destination, source, options: []|["ro"],
   type: {virtiofs:{}} | {volume:{name,format,cache,sync}} | {tmpfs:{}}}`.
   **Bind mounts report their type key as `virtiofs`** — the runtime's
   internal backing mechanism name, not a Capsule naming choice — and a
   tmpfs mount's `source` is the literal string `"tmpfs"`. `MountDetail.Kind`
   in `RuntimeModels.swift` decodes all three shapes plus an `.unknown`
   fallback for any future/unrecognized `type` key (decoded via a dynamic
   `CodingKey` so `allKeys` reflects whatever's actually present in the JSON,
   not just the cases this codebase happens to know about — a fixed `enum:
   CodingKey` would silently report `.unknown("")` for a truly novel key
   instead of naming it).
4. **`exec` propagates the inner command's exit code exactly.** `container
   exec <id> -- sh -c 'exit 7'` → CLI process exits 7. A non-zero exit is a
   legitimate `ExecResult`, never a thrown error — `CLIProcessClient.exec`
   bypasses `invoke`'s exit-code guard and calls `Subprocess.run` directly.
5. **stdout/stderr are split per command, and it varies by command:**
   `create`/`run` put the container id alone on stdout with `[n/6] …`
   progress noise on stderr; `logs` emits to stdout; `image pull --progress
   plain` emits progress to **stderr** with stdout empty. `CLIProcessClient`
   picks the fd per command accordingly (`SubprocessLineStream`'s
   `readFrom:` parameter).
6. **`container stats --format json` streaming mode is a dead end** — see
   the correction added to finding #9 of
   `2026-07-12-runtime-cli-observations.md`: it emits exactly one array and
   then goes silent forever (confirmed over a 25s trial), so P1A implements
   `stats` as a poll loop over `--no-stream` instead of a real stream.
7. **`container create` has no `--progress` flag at all** (exit 64 if
   passed) — unlike `image pull`, which requires `--progress plain`
   explicitly to get line-oriented, ANSI-free stderr output. Don't
   copy-paste the pull flag onto `create`.

## Finding — a Subprocess cancellation edge case (swift-concurrency-pro territory)

**Context:** writing `SubprocessEscalationTests`'s SIGTERM-ignored →
grace → SIGKILL test, using the brief's literal probe script: `/bin/sh -c
'trap "" TERM; echo up; sleep 30'`.

**Finding:** `Subprocess.run`'s completion rendezvous requires **both**
pipes (stdout, stderr) to reach EOF *and* the termination handler to fire
(this is deliberate — see the type's doc comment, "output is never
truncated by the exit racing the reads"). SIGKILL-ing the direct child (the
trapping `sh`) does make that process disappear immediately, satisfying the
termination handler — but `sh -c '…sleep 30'` forks `sleep 30` as a
*grandchild*, which inherits `sh`'s copies of the pipe write-end file
descriptors purely as a side effect of `fork`+`exec` (it never touches
them). Even after `sh` is gone, `sleep` keeps holding those descriptors
open, so the pipes never see EOF until `sleep` itself exits — up to its
full 30 seconds, regardless of how aggressively the direct child was
killed. First attempt at this test hung for the full 30s, exposing exactly
this.

**Consequence:** `Subprocess.run`'s cancellation path now has a second,
narrower escalation stage purely to bound this case: after the
grace-period SIGKILL, a short additional window (300ms) is given for a
*natural* EOF; if the rendezvous still hasn't completed by then (i.e. some
descendant is still holding a pipe open), the coordinator force-resolves
using whatever output was captured so far, tagging a synthetic exit code
(137, the shell convention for "killed by SIGKILL") only if the real one
never arrived either. This makes `Subprocess.run` itself return/throw
promptly regardless of this pathology — but it is a narrower fix than a
true process-group kill: the orphaned grandchild (here, `sleep`) is *not*
itself killed by this fallback and may continue running independently
until it exits on its own. `SubprocessLineStream` (used for `logs`/
`image pull`) does **not** carry this same fallback — those wrap a single
compiled binary (`container`), not a shell forking descendants, so signal
escalation of the one process it launches is sufficient for that surface's
actual production shape. `SubprocessLineStreamTests`' cancellation test
deliberately avoids the shell+grandchild pattern (uses a single-process
busy-wait instead) to keep that distinction honest rather than relying on
a fallback that file doesn't have.

**Falsifiability note:** if a real `container` subcommand is ever found to
fork+exec its own descendants in a way that inherits `SubprocessLineStream`'s
pipe descriptors (unlike every command probed for P1A, all single-process
invocations), the same "grandchild holds the pipe open" pathology would
apply there too and the fallback would need porting over.

## Consequences

- `RunSpec.swift`'s argv-mapping doc comment is updated to the corrected
  mount-flag shape (finding #2 above).
- `RuntimeModels.swift` gains `MountDetail`/`ContainerDetail.mounts`
  (additive, defaulted init param — no frozen signature change).
- `docs/learnings/2026-07-12-runtime-cli-observations.md` finding #9 is
  corrected in place (the "one array per tick" streaming claim was wrong).
- `Subprocess.swift`'s cancellation path gets the grace-period fallback
  described above; `SubprocessLineStream.swift` intentionally does not.
