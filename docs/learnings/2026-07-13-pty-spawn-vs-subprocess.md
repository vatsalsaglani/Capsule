# PTY spawn (`PTYExecSession`) vs. the `Subprocess`/`SubprocessLineStream` pattern

**Context:** P1C implementation (`Sources/TerminalKit/PTY.swift` +
`PTYExecSession.swift`) — building the raw-PTY spawn path S3 decided on
(`docs/spikes/S3-pty-exec.md`), reusing as much of `ContainerClient`'s proven
subprocess discipline (rule 3, AGENTS.md) as the PTY requirement allows.

## Finding 1 — `forkpty`/`fork`+`exec` cannot reuse `Foundation.Process` at all

`Subprocess.swift`/`SubprocessLineStream.swift` both wrap `Foundation.Process`
(a `Pipe`-based stdio model) and lean on its `terminationHandler`/
`waitUntilExit()` for reaping. That entire model is unavailable for the PTY
case: `container exec -it` needs its stdio to be a *real* PTY slave (S3,
finding: non-PTY stdio fails immediately with `Inappropriate ioctl for
device`), and `Foundation.Process` has no API to hand it a PTY slave as
stdio while also getting session-leader/controlling-terminal semantics
(`setsid` + `TIOCSCTTY`) — that combination is what `login_tty()` (bundled
inside Darwin's `forkpty()`) provides, and only a raw `fork()` gets you into
a position to call it. Consequence: `PTYExecSession` has **no `Process`
object at all** — cross-context state is `masterFD`/`childPID`, both bare
`Int32`, both trivially `Sendable`. This is actually a *simpler* Sendable
story than `Subprocess.swift`'s (which needs `UncheckedSendableBox` to
smuggle a `Process` reference into a detached escalation task) — there is
nothing here that ever needs `@unchecked Sendable`.

## Finding 2 — reaping can't reuse `waitUntilExit()`'s blocking semantics either

`SubprocessLineStream` calls `process.waitUntilExit()` (blocking, but safe
there because it happens inside a plain background `Task`, off the
cooperative pool, backed by a real OS thread under the hood via
`Foundation.Process`). Doing the equivalent for a raw `fork()`ed child means
calling POSIX `waitpid()` directly — and a blocking `waitpid(pid, &status,
0)` on Swift's cooperative thread pool would tie up one of a small, fixed
number of worker threads for however long the child runs. `PTYExecSession`
instead polls `waitpid(pid, &status, WNOHANG)` in a loop with short
`Task.sleep` pauses in between (never blocking), triggered by the PTY
master's `FileHandle.readabilityHandler` reporting EOF (the child's PTY
slave closed) — the reap only starts once the child is expected to already
be gone or going, so the poll loop resolves in one or two 25ms iterations in
practice.

## Finding 3 — fork safety needs raw C buffers, not just "don't retain a class"

`SubprocessLineStream`'s fork-safety discipline (its doc comment) is about
never handing a non-`Sendable` `Process`/`Pipe` across a task boundary.
`PTYExecSession`'s fork-safety requirement is stricter and different in
kind: between `fork()` and `execv()`, the child is a single thread inside a
process whose *other* threads (frozen mid-instruction by the fork) may be
holding `malloc`/ARC-internal locks — so the child must not allocate or
touch any Swift `Array`/`String`/class *at all* until `execv` replaces the
process image. `PTY.spawn` handles this by building `argv` (and the
close-list below) as `UnsafeMutablePointer`-based raw C buffers *before*
`forkpty()`, so the child branch only ever dereferences pre-existing raw
memory and calls `close`/`execv`/`_exit` — no Swift `Array` subscripting
machinery, no ARC.

## Finding 4 — file-descriptor inheritance across `fork()` is a real, demonstrated hazard (found via test flakiness, not designed in)

While writing `Tests/TerminalKitTests/PTYExecSessionTests.swift`, the
SIGKILL-fallback test (`terminateFallsBackToSIGKILLWhenGracePeriodExpires`)
was intermittently making the **entire** `swift test` run take ~30s instead
of ~4s — roughly half the time, only when run as part of the full 157-test
suite, never when filtered down to `TerminalKitTests` alone. Individually,
every test (including the flaky-looking one) always reported a fast,
correct per-test duration; the stall was invisible to `swift-testing`'s own
per-test timers.

Root cause, confirmed with `lsof -p <swiftpm-testing-helper pid>` while a
full suite run was in flight: SwiftPM's `swiftpm-testing-helper` process
(the actual test binary) holds **dozens of open pipe file descriptors above
fd 2** — used for the framework's own concurrent-test output capture/IPC.
`forkpty()`/`login_tty()` only reassign fds 0/1/2 to the new PTY slave; every
*other* open fd in the process (these test-harness pipes included) is
inherited unchanged by the forked child, and transitively by anything *that*
child forks (e.g. a shell running `sleep N` as a foreground command). The
SIGKILL-fallback test's fixture (`sh -c 'trap "" INT; sleep N'`) forks
`sleep` as a genuine grandchild once a `trap` is set (no tail-call `exec`
optimization) — SIGKILLing the direct child (the shell, S3's documented
orphan caveat) leaves that grandchild running independently, *still holding
the inherited test-harness pipe fds open*, for the remainder of its `sleep`
duration. If those pipes aren't `O_CLOEXEC`, whatever's waiting for one to
reach EOF (the harness's own output-capture rendezvous, by inference) stalls
until the orphan finally exits — exactly the "grandchild holds a pipe fd
open" hazard `SubprocessLineStream.swift`'s doc comment already calls out
for the `Pipe`-based case, reproduced here for PTY/`fork()`.

**Fix:** `PTY.spawn` enumerates this process's currently-open fds above 2 via
`/dev/fd` in the **parent**, before `forkpty()` (ordinary Swift code, no
fork-safety constraint applies there), copies that list into a raw
`UnsafeMutablePointer<Int32>` buffer, and the **child** closes every fd in
that buffer before `execv`ing — standard subprocess-spawning hygiene,
implemented as raw `close()` calls on pre-computed values (async-signal-safe,
no Swift allocation, consistent with the fork-safety contract in Finding 3).
This eliminated the flakiness in ~14 consecutive full-suite runs after the
fix (down from roughly 50% failure). A narrow TOCTOU window remains in
principle (an fd opened by an unrelated concurrent test *after* the
parent-side enumeration but *before* `forkpty()` wouldn't be in the
close-list) — Darwin's Swift overlay doesn't expose `close_range()`
(confirmed: `swiftc -typecheck` fails with "cannot find 'close_range' in
scope" on macOS 26.1/Xcode 26.3), which would close that window atomically
in the child instead. Mitigated further by shrinking the test fixture's
`sleep 30` down to `sleep 4` (still safely longer than the 300ms
`terminateGrace` used in that test, just less exposure if the residual race
is ever hit). This is a test-environment-specific risk (a process forking
PTYs while dozens of *other* concurrent subprocess-spawning tests are also
running in the same process) — the production path (one `capsule`/Capsule.app
process, not a test-parallelism harness) doesn't have this same density of
inherited fds, so this is not expected to be a production concern, but the
`close`-fds-above-2 fix is correct, standard practice regardless of that.

## Finding 5 — `TIOCSWINSZ`/`ioctl` and `forkpty` ARE visible through the Darwin Swift overlay

Unlike the brief's stated fallback concern ("if Swift's Darwin overlay
doesn't expose `forkpty`, use the explicit `posix_openpt`/`grantpt`/
`unlockpt`/`fork`/`login_tty` sequence"): on this machine (macOS 26.1, Xcode
26.3, Swift 6.2), `import Darwin` exposes `forkpty`, `login_tty`, `winsize`,
`ioctl`, and `TIOCSWINSZ` directly — no C shim, no explicit-sequence
fallback needed. Verified with a standalone `swiftc -typecheck`/`swiftc`
probe before writing `PTY.swift` at all.

## Finding 6 — `TERM=xterm-256color` propagation, live-verified

The S3 spike didn't probe `TERM` specifically. Live-verified here against a
real `alpine:latest` container (`container exec -it -e TERM=xterm-256color
<id> sh`, driven through `PTYExecSession` directly, not a throwaway harness):
sending `echo TERM-IS-$TERM` returned `TERM-IS-xterm-256color` — the `-e
TERM=xterm-256color` flag (`container exec`'s documented `-e/--env` option)
propagates correctly into the container-side shell's environment. No
adjustment to the brief's argv (`["exec", "-it", "-e",
"TERM=xterm-256color", containerID, shell]`) was needed.

Also re-confirmed live, through `PTYExecSession` end to end (not just the
Python harness from S3): resize (`resize(columns: 111, rows: 37)` →
`stty size` → `37 111`), Ctrl-C interrupting a foreground `sleep` (exit
130 = 128+SIGINT), two simultaneous sessions into two *different* real
containers (alpine + debian) never cross streams, and the "container
stopped while attached" path — `container stop` on the target container
while a session was attached made the local `container exec -it` client
exit **on its own in ~80 microseconds**, reporting exit code 137
(128+SIGKILL) through `waitUntilExit()`, with no orphaned host-side process
and no zombie.

## Finding 7 — Swift 6.2 protocol conformance isolation bites `@MainActor` SwiftTerm delegates

Verified by compiling `App/Capsule/TerminalHostView.swift` against the *real*
SwiftTerm package (via a throwaway local SwiftPM probe depending on both
`https://github.com/migueldeicaza/SwiftTerm` and the local `CapsuleKit`
package, since `xcodebuild` is broken in this environment — see the App
verification note in the P1C report). SwiftTerm's `TerminalViewDelegate` is
declared `nonisolated`; a `@MainActor final class Coordinator: NSObject,
TerminalViewDelegate` alone is **not** sufficient in Swift 6.2's stricter
conformance-isolation checking — it fails with `error: conformance of
'Coordinator' to protocol 'TerminalViewDelegate' crosses into main
actor-isolated code and can cause data races [#ConformanceIsolation]`. Fix:
isolate the conformance explicitly in the inheritance clause — `final class
Coordinator: NSObject, @MainActor TerminalViewDelegate`. This is a
general Swift 6.2 nuance (any `@MainActor` type conforming to a
`nonisolated` protocol needs this), not SwiftTerm-specific, but SwiftTerm's
delegate is the first place this codebase hits it.

## Consequence

- `PTYExecSession` has zero `Process` objects and zero new `@unchecked
  Sendable` — cross-context values are exactly `masterFD`/`childPID`
  (`Int32`) plus the `AsyncStream.Continuation` (itself `Sendable`).
- `PTY.spawn`'s fork-safety contract now explicitly includes "close every
  inherited fd above 2 in the child" alongside "no Swift allocation between
  `fork` and `exec`" — both implemented with pre-computed raw buffers.
- `output: AsyncStream<Data>` uses `.unbounded` buffering, a deliberate,
  documented exception to the bounded-buffer default (`bug-patterns.md`):
  the sole consumer is one UI view draining at terminal-render speed (human
  typing / a foreground program's own output rate), and dropping any byte
  mid-escape-sequence would corrupt SwiftTerm's rendering rather than just
  delay it — unlike the high-throughput-producer case the bounded-buffer
  rule guards against.
- `waitForGracefulExit` (races `terminate()`'s cooperative-shutdown wait
  against `terminateGrace`) is **not** built on `withTaskGroup` — an earlier
  version was, and it silently failed to time out at all (see the bug this
  surfaced, documented in `PTYExecSession.swift`'s doc comment on that
  function): `withTaskGroup` waits for every child task before returning,
  even after `cancelAll()`, and a child suspended on a `waitUntilExit()`
  `CheckedContinuation` has no way to observe cancellation and resume early.
  The fix uses a dedicated actor-owned `CheckedContinuation<Bool, Never>`
  resumed exactly once by whichever of an unstructured timeout `Task` or
  `finish()` gets there first — deliberately *not* a structured child, so
  the loser never blocks the winner's return.
- SwiftTerm stays App-only (`App/project.yml`, not root `Package.swift`) —
  confirmed compiling cleanly against the real dependency via a throwaway
  local SwiftPM probe, working around this environment's broken
  `xcodebuild` (see the P1C report for exact repro).
