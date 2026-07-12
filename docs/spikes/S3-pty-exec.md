# S3 — PTY/exec interactive quality

**Status:** decided (2026-07-13)

## Question

Is `SwiftTerm` over `container exec -it` good enough for the Terminal
screen (P1C)? Specifically, against `container` 1.1.0:

1. TTY allocation — does `container exec -it <id> sh` allocate a PTY inside
   the container (`tty` prints a device, `test -t 0` succeeds)?
2. Colors — does a TERM-aware program's raw ANSI escape bytes survive the
   exec round trip to the PTY master?
3. Resize (SIGWINCH) — does a `TIOCSWINSZ` on the PTY master propagate to the
   container-side shell (`stty size` reflects it)?
4. Ctrl-C — does writing `0x03` to the PTY master interrupt a running
   foreground process inside the container?
5. Line editing — does cooked-mode backspace work at a shell prompt?
6. Shell auto-detection order — what shells actually exist in alpine and
   debian images, to ground P1C's sh/bash/ash fallback order?

Decides master plan §3 "Terminal" row and unblocks P1C
(`docs/plans/phases/P1C-terminal.md`).

## Machine state (reconfirmed before starting)

```
$ container --version
container CLI version 1.1.0 (build: release, commit: 5973b9c)
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED
```

Clean slate: no containers running before this spike started.

## Method

A throwaway Python PTY harness (Python's `pty`/`fcntl`/`termios`/`select`,
chosen for speed — this is disposable, not production code) drives the
interactive behaviors. It lives only in the session scratchpad
(`/private/tmp/.../scratchpad/s3-harness/pty_harness.py`, **not** committed —
per the brief, described here instead of kept under
`docs/spikes/s3-harness/`). Its logic, verbatim in spirit:

```python
pid, master_fd = pty.fork()
if pid == 0:
    os.execvp("container", ["container", "exec", "-it", "s3-probe", "sh"])
else:
    # parent drives scripted input over master_fd and logs raw output bytes
    send(b"tty\n")
    send(b"test -t 0 && echo TTY-OK || echo TTY-FAIL\n")
    send(b"printf '\\033[31mRED\\033[0m\\n'\n")
    send(b"stty size\n")
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 120, 0, 0))
    send(b"stty size\n")                       # after resize
    send(b"echo HELLXX"); send(b"\x7f\x7f"); send(b"\n")   # backspace test
    send(b"sleep 100\n"); send(b"\x03")          # ctrl-c test
    send(b"which sh bash ash 2>&1\n")
    send(b"exit\n")
```

Setup and exact commands run, in order:

```sh
container run -d --name s3-probe docker.io/library/alpine:latest sleep 3600
python3 pty_harness.py ./s3-log.txt        # drives container exec -it s3-probe sh
od -c s3-log.txt                            # raw byte inspection

# shell inventory, both images
container exec s3-probe sh -c 'ls -1 /bin/sh /bin/bash /bin/ash 2>&1; readlink -f /bin/sh; which sh bash ash dash 2>&1'
container run -d --name s3-probe-debian docker.io/library/debian:latest sleep 3600
container exec s3-probe-debian sh -c 'ls -1 /bin/sh /bin/bash /bin/ash /bin/dash 2>&1; readlink -f /bin/sh; which sh bash ash dash 2>&1'

# -i / -t flag semantics
container exec -t s3-probe sh -c 'tty; test -t 0 && echo TTY-OK-STDIN || echo TTY-FAIL-STDIN'
container exec -i s3-probe sh -c 'tty; test -t 0 && echo TTY-OK-STDIN || echo TTY-FAIL-STDIN' <<< ""
container exec    s3-probe sh -c 'tty; test -t 0 && echo TTY-OK-STDIN || echo TTY-FAIL-STDIN'
container exec s3-probe sh -c 'exit 42'; echo "cli-exit:$?"

# client-process signal handling + container-side orphan check (extra probe,
# added once the brief's checklist passed and P1C deliverable #4 — "no
# zombie processes" — needed grounding)
python3 - <<'PY'
pid, master_fd = pty.fork()
if pid == 0:
    os.execvp("container", ["container", "exec", "-it", "s3-probe", "sh", "-c", "sleep 60"])
# parent: send SIGTERM / SIGINT / SIGKILL to the *local client pid*, poll
# waitpid, then check `container exec s3-probe sh -c 'ps aux'` for orphans
PY

# container-stop-while-attached probe
python3 - <<'PY'
# same fork/exec, then `container stop s3-probe` from a second process while
# attached, poll waitpid for the local client's own exit
PY
```

## Result

### Per-behavior table

| # | Behavior | Result | Evidence |
|---|---|---|---|
| 1 | TTY allocation | **PASS** | `tty` → `/dev/pts/0`; `test -t 0 && echo TTY-OK` → `TTY-OK` |
| 2 | Colors (raw ANSI survive) | **PASS** | raw bytes captured verbatim (see below) |
| 3 | Resize propagation | **PASS** | `stty size` before resize errored (`stty: standard input` — no initial winsize set by `pty.fork()`, a harness artifact, not a `container` behavior); after `TIOCSWINSZ(rows=50,cols=120)` on the master, `stty size` inside the container printed `50 120` exactly |
| 4 | Ctrl-C interrupts foreground process | **PASS** | `sleep 100` running, `0x03` written to master → `^C` echoed, prompt returned; follow-up `echo AFTER-CTRLC-$?` → `AFTER-CTRLC-130` (130 = 128+SIGINT, confirming the foreground `sleep` itself received the interrupt, not just a local echo) |
| 5 | Line editing (cooked mode) | **PASS** | typed `echo HELLXX`, 2× backspace, `\n` → output `HELL` (bytes: `H E L L X X \b \033[J \b \033[J \r\r\n H E L L`) — busybox's cooked-mode local echo emits `\b ESC[J` per erased char, standard behavior |
| 6 | Shell inventory | **PASS (informational)** | see below |

Raw byte evidence for #2 (colors), from `od -c`:

```
p   r   i   n   t   f       '   \   0   3
3   [   3   1   m   R   E   D   \   0   3   3   [   0   m   \
n   '  \r  \r  \n 033   [   3   1   m   R   E   D 033   [   0
m  \r  \r  \n
```

The raw `ESC [ 3 1 m R E D ESC [ 0 m` bytes (octal `033` = `ESC`, i.e.
`\x1b[31mRED\x1b[0m`) are present unescaped in the PTY master's read stream —
`container exec -it` does not strip or translate ANSI escapes.

Raw byte evidence for #3 (resize), from `od -c`:

```
=== stty size BEFORE resize ===
stty size\r\r\n stty: standard input\r\r\n     <- harness artifact: winsize
                                                   never set before this point
=== stty size AFTER resize (expect '50 120') ===
\r/ # \033[J stty size\r\r\n 5 0   1 2 0 \r\r\n
```

`50 120` matches the `TIOCSWINSZ` request (rows=50, cols=120) exactly — no
explicit `SIGWINCH` send was required from the harness; the kernel delivers
`SIGWINCH` to the local client's foreground process group automatically on
`TIOCSWINSZ`, and `container exec -it` forwards the new size to the
container-side PTY on its own.

### Shell inventory (informational, grounds P1C's detection order)

**alpine:latest** (`docker.io/library/alpine:latest`, arm64, same digest as
prior spikes):
```
$ ls -1 /bin/sh /bin/bash /bin/ash
ls: /bin/bash: No such file or directory
/bin/ash
/bin/sh
$ readlink -f /bin/sh
/bin/busybox
$ which sh bash ash dash
/bin/sh
/bin/ash
```
`/bin/sh` and `/bin/ash` both resolve to the busybox multi-call binary. **No
`bash`, no `dash`.**

**debian:latest** (`docker.io/library/debian:latest`, arm64):
```
$ ls -1 /bin/sh /bin/bash /bin/ash /bin/dash
ls: cannot access '/bin/ash': No such file or directory
/bin/bash
/bin/dash
/bin/sh
$ readlink -f /bin/sh
/usr/bin/dash
$ which sh bash ash dash
/usr/bin/sh
/usr/bin/bash
/usr/bin/dash
```
`/bin/sh` → `dash`. **`bash` and `dash` present, no `ash`.**

Master plan §3's stated fallback order is "sh/bash/ash". Given the above,
that literal order works on both images (both have `/bin/sh`), but it's
worth noting `sh` alone would already succeed on both — `bash`/`ash` are only
reached if a future minimal image lacks even `sh` (unlikely; POSIX `sh` is
close to universal on Linux base images). Recommend keeping the documented
order sh → bash → ash but noting `ash` is alpine/busybox-specific and `bash`
is the common non-alpine case; a fourth `dash` fallback is not needed since
every image with `dash` also has `sh` pointing at it.

### `-i`/`-t` flag semantics

```
exec -t only (no -i): tty → /dev/pts/0, test -t 0 → TTY-OK-STDIN
exec -i only (no -t): tty → not a tty,   test -t 0 → TTY-FAIL-STDIN
exec plain (no -i -t): tty → not a tty,  test -t 0 → TTY-FAIL-STDIN
```

`-t` is what allocates the PTY; `-i` alone does not. **P1C must pass both
`-i` and `-t`** (as the brief already assumed) — `-i` keeps stdin open/wired
for interactive input, `-t` is what makes it a TTY. This matches Docker's
`-it` convention exactly.

Also confirmed: a real PTY is required for `-it` at all — driving
`container exec -it` through a plain (non-PTY) pipe (e.g. `subprocess.Popen`
without `pty.fork()`) fails immediately, client-side, with `Error: failed to
exec process ... Code=25 "Inappropriate ioctl for device"`. This reinforces
that P1C's `PTYExecSession` must allocate a real PTY for the exec's stdio,
not merely pipe stdin/stdout.

Exit-code propagation reconfirmed consistent with
`2026-07-13-p1a-implementation-notes.md`: `container exec s3-probe sh -c
'exit 42'` → CLI process exits `42`.

### MAJOR finding — client-process signal handling differs sharply from `build` (S5)

This surfaced while grounding P1C deliverable #4 ("container stops → session
shows a clear exited state, no zombie processes — verify with `ps`") and is
**not** in the brief's checklist verbatim, but is directly load-bearing for
`PTYExecSession.terminate()`'s design, so it's recorded as part of this
spike's decision rather than deferred.

Unlike `container build` (S5: SIGINT/SIGTERM both handled gracefully in
<1s), the `container exec -it` **client process ignores SIGTERM and SIGINT
entirely** — sent both, polled `waitpid` for 10s and 5s respectively, the
process never exited on its own in either trial. Only **SIGKILL** ends the
local client process, immediately.

Worse: SIGKILL of the local `container exec -it` client **does not** tear
down the corresponding process inside the container (unlike S5's builder
session, which *is* torn down automatically on client disconnect). A
foreground `sleep 60` exec'd via `-it`, whose local client was then
SIGKILLed, left the container-side `sleep 60` **running as an orphan**
(confirmed via a separate `container exec s3-probe sh -c 'ps aux'` showing
the process still alive, PID unchanged, well after the local client was
gone). This was reproduced twice (once each for the SIGTERM-then-SIGKILL and
SIGINT-then-SIGKILL trials).

However, when the **container itself is stopped** while an `exec -it`
session is attached (`container stop s3-probe`), the local client detects
the disconnect and **exits on its own, immediately** (`waitpid` returned
within the same iteration as the stop call, i.e. sub-100ms), with exit code
`137` (`128 + SIGKILL`, the conventional "container was killed out from under
you" exit code). No local orphan process, no hang — because the whole VM
(and everything running inside it) is torn down, the orphan-inside-container
concern is moot for this path specifically.

**Consequence for P1C:** `terminate()` cannot rely on signaling the local
client process at all for cooperative shutdown (SIGTERM/SIGINT are both
no-ops there) — it must **terminate over the PTY channel itself**: write
Ctrl-C (`0x03`) to interrupt any foreground command, then write `exit\n` (or
EOF/`0x04`) to end the shell cleanly, with a short bounded grace period,
observing the local client's own process exit as the completion signal.
Only if that graceful path doesn't complete within the grace period should
`PTYExecSession` fall back to SIGKILL-ing the local client — accepting that
this fallback may leave an orphaned process inside the container (a
container that's still running). This is a real but narrow gap: it only
matters if a user force-closes a terminal tab while a long-running foreground
command is executing and the graceful PTY-level shutdown itself hangs — the
common paths (idle prompt, or container stopped/deleted) are both clean.

## Decision

1. **SwiftTerm viable?** **Yes.** All five core interactive behaviors (TTY
   allocation, colors, resize, ctrl-c, line editing) pass cleanly through
   `container exec -it`, at the raw-byte level SwiftTerm expects to consume
   (`feed(byteArray:)` on a `TerminalView`) or produce (a
   `LocalProcess`-style writer). No evidence of escape stripping, PTY
   emulation gaps, or resize/signal blackholes in the paths the Terminal
   screen actually needs.

2. **Which PTY-spawn path does P1C use?** **TerminalKit owns the PTY and
   drives SwiftTerm's `feed(byteArray:)`; do not use SwiftTerm's
   `LocalProcess`.** Reasoning:
   - AGENTS.md rule 3 (subprocess discipline: argv arrays, explicit
     timeouts/cancellation, typed `RuntimeError` with real stderr) already
     has a home in `Subprocess`/`CLIProcessClient` — SwiftTerm's
     `LocalProcess` wants to own the child `Foundation.Process` lifecycle
     itself (its own spawn, its own read loop, its own termination
     handling), which doesn't compose with that existing discipline or with
     `ContainerRuntime`'s testability contract (rule 2: all runtime access
     goes through the protocol; a `TerminalSession` conforming to the
     existing `Sources/TerminalKit/TerminalKit.swift` protocol needs to be
     fake-able in tests without SwiftTerm at all).
   - The signal-handling finding above is decisive on its own: since
     graceful shutdown must happen *over the PTY bytes* (Ctrl-C + exit),
     not via process signals, `PTYExecSession` needs direct control of the
     master fd and the child pid regardless of what UI library sits on top.
     Handing process ownership to SwiftTerm would fight this.
   - This also matches the module boundary already implied by
     `TerminalKit.swift`'s existing protocol comment ("the SwiftTerm-backed
     implementation... lands in M1... the protocol exists now so ViewModels
     never touch SwiftTerm directly") and P1C's own deliverable #1 language
     ("No SwiftTerm import inside TerminalKit if S3 chose raw PTY").
   - Concretely: `PTYExecSession` (TerminalKit, PTY-only, `posix_openpt`/
     `forkpty` via a small C shim or `Glibc`/`Darwin` PTY calls) exposes
     `output: AsyncStream<Data>`, `send(_:)`, `resize(columns:rows:)`,
     `terminate()`. `App/` wraps SwiftTerm's `TerminalView`, feeds it bytes
     from `output`, and forwards `TerminalView` input/resize callbacks into
     `send`/`resize`. SwiftTerm's own process-spawning code path is unused.

3. **Shell detection order confirmed:** `sh` → `bash` → `ash`, as already
   documented in master plan §3, is grounded and sufficient: alpine has
   `sh`/`ash` (busybox, no `bash`), debian has `sh`/`bash`/`dash` (no `ash`).
   Every image tested has `/bin/sh` at minimum, so `sh` is the connecting
   shell in practice for both; `bash`/`ash` only matter as fallbacks for
   images where `sh` itself is missing or non-functional (not observed here,
   but the fallback chain is cheap insurance).

4. **Resize protocol:** `PTYExecSession.resize(columns:rows:)` issues
   `TIOCSWINSZ` directly on **the master fd it owns** (the local end of the
   PTY it allocated for the `container exec -it` child). No explicit
   `SIGWINCH` send is needed — the kernel handles delivering `SIGWINCH` to
   the client's foreground process group automatically on `TIOCSWINSZ`, and
   `container exec -it` itself forwards the new size into the container-side
   PTY (confirmed empirically above, not merely assumed).

5. **Gotchas for P1C:**
   - `container exec` needs **both** `-i` and `-t` — `-t` alone allocates the
     PTY; `-i` alone does not. Confirmed via `test -t 0` returning false with
     `-i` only or with neither flag.
   - Exec's stdio **must be a real PTY**, not just any pipe — driving
     `-it` through non-PTY stdio fails immediately client-side
     (`Inappropriate ioctl for device`). `PTYExecSession` must allocate an
     actual PTY (as the brief already specified), not just wire up
     `Process.standardInput`/`standardOutput` pipes.
   - Exit code propagates exactly (matches existing
     `2026-07-13-p1a-implementation-notes.md` finding for non-interactive
     `exec`).
   - **`terminate()` must go over the PTY bytes (Ctrl-C then exit/EOF,
     bounded grace period), not process signals** — SIGTERM/SIGINT are
     no-ops against the local `container exec -it` client. SIGKILL as a
     last-resort fallback works locally but can orphan a process inside a
     *still-running* container; this is an accepted narrow gap (see MAJOR
     finding above), not a blocker — it only bites the "force-close a tab
     with a hung foreground command" edge case, and the orphan disappears
     the moment that container is stopped or deleted regardless.
   - When the container itself stops/is deleted while a session is
     attached, the local `container exec -it` client exits **on its own**
     (observed sub-100ms, exit code 137) — `PTYExecSession` should treat
     that specific exit code (or more robustly, any exit while the
     container's own state has transitioned away from running) as the
     signal to show the "exited" state, not surface it as an error.

## Cleanup verification

```
$ container delete -f s3-probe
s3-probe
$ container delete -f s3-probe-debian
s3-probe-debian
$ container ls --all | grep s3- || echo "no s3 containers (good)"
no s3 containers (good)
```

## Harness disposition

The Python PTY harness (`pty_harness.py`) was written and run only in the
session scratchpad, **not committed** — this document's Method section
reproduces its logic and exact commands verbatim (in spirit) for
reproducibility. It was not kept under `docs/spikes/s3-harness/` since a
plain script description here is sufficient and keeps the diff for this
spike purely documentation.
