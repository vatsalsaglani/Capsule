# S5 — build streaming + cancellation

**Status:** decided (2026-07-13).

## Question

SIGINT/SIGTERM semantics of `container build`: does cancelling a build leave
the builder subsystem consistent? Does `Subprocess`'s SIGTERM-only
`terminate()` (`Sources/ContainerClient/Subprocess.swift:61-64`) suffice, or
is SIGKILL escalation required — and if so, with what grace period? What must
the UI warn about re: builder state after a cancelled build?

Decides master plan §3 (Builds screen: "streamed output, cancel") and §5
risks, and the P1A subprocess-hardening TODO.

## Machine state (reconfirmed before starting)

```
$ container --version
container CLI version 1.1.0 (build: release, commit: 5973b9c)
$ container builder status
builder is not running
$ container build --help
OVERVIEW: Build an image from a Dockerfile or Containerfile
...
  --progress <type>       Progress type (format: auto|plain|tty) (default: auto)
  ...
```

**Precondition, recorded per the brief:** the builder was **not running**
before this spike (`builder is not running` — not even a stopped builder
container existed). Every builder container ("buildkit") observed during this
spike was therefore started by this spike's own `container build` invocations
(builds auto-start the builder if it isn't already running — no explicit
`container builder start` was ever issued). Cleanup fully deletes the builder
container so the machine returns to the exact same "builder is not running"
state — not merely "stopped" (see Cleanup section; `stopped` and "not
running/no container" are observably different states in this CLI).

## Method (exact commands, in order)

All work happened in the session scratchpad
(`/private/tmp/claude-501/.../scratchpad/s5-build`), never in the repo.

### 1. Scratch build context

```dockerfile
# Dockerfile
FROM docker.io/library/alpine:latest
RUN sleep 120
```

A second `Dockerfile.quick` (`RUN echo "..."`) was used between signal tests
to verify the builder was still usable without waiting on a fresh 120s sleep
each time.

### 2. SIGINT test

```sh
container build --progress plain -t s5-img -f Dockerfile . > build_sigint.log 2>&1 &
# PID=71787; polled log until "RUN sleep 120" step reached (~18s: image
# resolve/pull/extract steps first)
kill -INT 71787
```

Verbatim tail of `build_sigint.log` after the signal:

```
#5 [linux/arm64 1/2] RUN sleep 120
Error: interrupted: "exiting on signal 2"
```

Process exited within 1s of the signal (polling granularity was 1s; the
process was already gone on the first poll). Immediately after:

```
$ container builder status
ID        IMAGE                                                STATE    IP               CPUS  MEMORY
buildkit  ghcr.io/apple/container-builder-shim/builder:0.12.0  running  192.168.64.8/24  2     2048 MB
$ container ls --all
ID        IMAGE                                                OS     ARCH   STATE    IP               CPUS  MEMORY   STARTED
buildkit  ghcr.io/apple/container-builder-shim/builder:0.12.0  linux  arm64  running  192.168.64.8/24  2     2048 MB  2026-07-12T21:05:37Z
```

`buildkit` "running" here is its normal idle state (it's the persistent
builder VM/container, not a per-build resource — do not confuse this row with
an orphaned build). To confirm the builder was actually idle and not merely
reporting a stale "running" state, a follow-up build was run immediately:

```sh
$ time container build --progress plain -t s5-verify -f Dockerfile.quick .
...
s5-verify:latest
container build ... 0.05s user 0.03s system 6% cpu 1.145 total
```

Completed in ~1.1s with no contention — builder fully consistent after
SIGINT.

### 3. SIGTERM test

Same procedure, fresh long build, `kill -TERM <pid>`:

```
#5 [linux/arm64 1/2] RUN sleep 120
Error: interrupted: "exiting on signal 15"
```

Process gone on the first 1s poll (i.e. exit in well under 1s — indistinguishable
from the SIGINT timing at this measurement granularity). Builder status
immediately after: `buildkit ... running` (same idle-state row as above).
Follow-up verification build (`s5-verify2`) completed in ~1.1s, confirming the
builder was not wedged.

**SIGTERM behaves identically to SIGINT**: the CLI installs its own signal
handler, prints a matching `Error: interrupted: "exiting on signal <N>"`, and
exits promptly. There is no observable difference in speed or builder
consistency between the two signals.

### 4. SIGKILL test (the escalation being evaluated)

Fresh long build, `kill -KILL <pid>` (bypasses any signal handler — the
process cannot run cleanup code):

```
$ kill -KILL 71878
# process gone on first 1s poll
$ tail build_sigkill.log
#5 [linux/arm64 1/2] RUN sleep 120
   <log ends here — no "Error: interrupted" line, as expected: the killed
   process never got to write one>
$ container builder status
ID        IMAGE                                                STATE    IP               CPUS  MEMORY
buildkit  ghcr.io/apple/container-builder-shim/builder:0.12.0  running  192.168.64.8/24  2     2048 MB
```

The critical check — is the `RUN sleep 120` step still executing inside the
builder VM as an orphan, invisible from the host CLI's perspective?

```sh
$ container exec buildkit ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /usr/local/bin/container-builder-shim --debug --vsock
   10 root      0:00 /usr/bin/buildkitd
  186 root      0:00 ps aux
```

**No orphaned `sleep` process.** The builder-side session for the killed
build was torn down even though the client process never got a chance to
signal cancellation intent — this is consistent with the builder detecting
the vsock/gRPC connection drop (which happens automatically at the OS level
when a process's file descriptors are closed, including on SIGKILL) and
cancelling the in-flight build step server-side.

A follow-up build (`s5-verify3`) run immediately after the SIGKILL, with no
delay, completed in 0.155s total (fully cached) with no queuing/blocking
behavior — the builder was not busy or exclusively locked by the killed
build's residue.

`container system logs --last 5m` was checked for corroborating detail; the
apiserver-level log (Info/Error only, no `--debug`) contains builder-startup
plugin/network records but no per-build session detail, so it neither
confirms nor contradicts the `ps aux` finding — the `ps aux` result inside the
builder container is the authoritative evidence here.

### 5. `--progress` format check (streaming shape for P1A)

```sh
$ container build --progress auto -t s5-verify4 -f Dockerfile.quick . > build_auto.log 2>&1
$ od -c build_auto.log | grep -m5 '\\r\|033'      # no ANSI escapes, no \r found
$ grep -c $'\r' build_auto.log                     # 0
$ grep -c $'\r' build_sigint.log                    # 0 (plain mode, for comparison)
```

Both `--progress plain` and `--progress auto` (when stdout is not a TTY —
which is always true for `Subprocess`'s `Pipe`-based capture) produce
identical, plain-text, `\n`-terminated, ANSI-free output: lines like
`#5 [linux/arm64 1/2] RUN sleep 120`, `#5 DONE 0.1s`, one build step / status
transition per line. No carriage returns or cursor-control sequences were
found in either mode's output. `auto` evidently detects the non-tty pipe and
falls back to the same rendering as `plain`.

## Result — per-signal table

| Signal | Time to CLI exit | stderr/log evidence | Builder state after | Orphan build inside builder VM? |
|---|---|---|---|---|
| SIGINT (Ctrl-C) | < 1s (observed on first 1s poll) | `Error: interrupted: "exiting on signal 2"` | `running` (idle) — verified consistent via follow-up build (1.1s, no contention) | No |
| SIGTERM (`Process.terminate()` today) | < 1s (same as SIGINT at this granularity) | `Error: interrupted: "exiting on signal 15"` | `running` (idle) — verified consistent via follow-up build (1.1s, no contention) | No |
| SIGKILL (escalation under evaluation) | < 1s (process gone, no chance to log) | none (process had no opportunity to write) | `running` — verified consistent: `container exec buildkit ps aux` shows only the shim/buildkitd processes, no orphaned `sleep`; follow-up build ran instantly (0.155s) with no queuing | No |

All three signals produced a **consistent, idle builder** afterward, verified
two ways: (1) `container builder status`/`container ls --all` showing the
persistent `buildkit` container in its normal `running` state rather than an
error/wedged state, and (2) empirically, by running a fresh build immediately
after each test and confirming it completed fast with no contention, plus
(for SIGKILL specifically) `container exec buildkit ps aux` showing no
orphaned build process.

## Decision

1. **Signal choice + escalation.** `SIGTERM` alone was sufficient in every
   trial — the CLI installed a handler, printed `Error: interrupted: "exiting
   on signal 15"`, and exited in well under 1 second, every time. **No
   SIGKILL escalation was empirically required for `build`** in this runtime
   version. That said, the recommended *defensive* contract for `Subprocess`
   is still: `terminate()` (SIGTERM) → wait a grace period → `kill(SIGKILL)`
   if still running. Recommended grace period: **5 seconds** — generous
   relative to the observed <1s exit time (headroom for slower machines, a
   larger build graph, or a future CLI version whose signal handling regresses),
   without meaningfully delaying a user-initiated cancel. This is a safety-net
   contract, not a fix for an observed hang.

2. **Is the lines 61-64 TODO ("escalate SIGTERM → SIGKILL... matters for
   build, spike S5") confirmed necessary for build specifically? No — not on
   correctness grounds.** SIGTERM-only `terminate()` was observed to work
   correctly for `build` in every trial: process exits fast, builder stays
   consistent, no orphan. The TODO is still worth implementing in P1A, but
   reframed: it's **general defense-in-depth for `Subprocess` as a whole**
   (guards against a future hang in *any* spawned command — build or
   otherwise — not a build-specific correctness fix), not evidence-driven
   urgency for `build`. P1A should implement the 5s-grace SIGKILL escalation
   as a generic `Subprocess` improvement, and can note in its PR that build
   specifically did not require it in this spike.

3. **Builder-state caveat for the UI:** based on this spike, the builder was
   **never observed to become inconsistent or wedged** after a cancelled
   build, across SIGINT, SIGTERM, and even SIGKILL of the CLI process. The UI
   does **not** need a mandatory "reset builder" affordance for the cancel
   path. Two caveats to carry forward, both documented rather than silently
   assumed:
   - This is evidence from **one** runtime version (1.1.0) and a small number
     of trials against a single slow `RUN sleep` layer. It is not proof the
     builder can never wedge (e.g. a killed build mid-*layer-export* or
     mid-*registry-push* was not tested — those are different failure
     surfaces than a killed `RUN`). Recommend a **defensive, not load-bearing**
     "Reset Builder" affordance in the Builds screen regardless (calls
     `container builder stop` then `container builder start`, or
     `container builder delete` then a fresh build re-auto-starts it) — cheap
     insurance, not a fix for something broken.
   - Recovery commands, if ever needed: `container builder stop` (stop only),
     or `container builder delete [--force]` (fully remove; a subsequent
     build auto-restarts it). `--force` deletes even if still reported
     running — the escape hatch if `stop` itself seems unresponsive.

4. **Streaming note — confirmed.** `--progress plain` is exactly the
   line-oriented, ANSI-free, `\n`-terminated stream P1A's build-streaming
   needs for `FileHandle.bytes → AsyncThrowingStream` (one build step /
   status line per read). **Recommendation: use `--progress plain`
   explicitly** (not `auto`) — `auto`'s non-tty output was observed to look
   identical in this version, but pinning `plain` removes any dependency on
   `auto`'s tty-detection behavior remaining backward compatible across CLI
   updates. `tty` mode was not tested (irrelevant to `Subprocess`, which never
   attaches a real tty).

5. **Interaction with cancellation of other long ops (logs/pull/exec).** Not
   independently re-tested here (out of S5's scope — `pull`/`logs`/`exec`
   don't have an external "builder VM" consistency question the way `build`
   does), but the observed mechanism generalizes safely: `container build`'s
   clean exit on SIGINT/SIGTERM comes from the CLI's own signal handling
   (shared ArgumentParser-based CLI, not build-specific code), and the
   orphan-free behavior even under SIGKILL comes from OS-level fd/connection
   teardown, not build-specific cleanup logic. Both properties should hold
   equally for `logs --follow`, `pull`, and `exec` subprocesses. **The
   SIGTERM→SIGKILL-with-5s-grace contract recommended in point 1 is safe to
   apply uniformly to all `Subprocess`-spawned children** — it does not need
   to be build-specific. (If a future spike finds a long-op command that
   *does* need special handling, e.g. `exec -it` under a PTY where SIGKILL
   might strand a remote shell, amend this point then — no evidence for that
   in this spike.)

## Cleanup — verified back to pre-spike state

```sh
$ container image ls | grep s5   # (after deleting s5-img*/s5-verify*)
                                   → no output
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED   (empty, same as pre-spike)
$ container builder delete       # builder was NOT running pre-spike; this spike
                                  # started it via `container build` auto-start,
                                  # so it — not a pre-existing user builder — was
                                  # torn down fully (stop alone leaves a `stopped`
                                  # row, which is a different state than the
                                  # pre-spike "no container" state; `delete` restores
                                  # the exact original condition)
$ container builder status
builder is not running            # exact match to the pre-spike output
```

Scratch build context (`.../scratchpad/s5-build`) deleted. `alpine:latest`
and `nginx:latest` (pulled by earlier S1/S2 spikes, not this one) were left
untouched.
