# `container exec -it` PTY behavior + Terminal (P1C) integration path

**Context:** S3 spike (`docs/spikes/S3-pty-exec.md`) — deciding whether
SwiftTerm over `container exec -it` is viable for the Terminal screen, and
which PTY-spawn path P1C's `PTYExecSession` should use, ahead of the P1C
implementation.

**Finding (`container` CLI 1.1.0, verified with a Python `pty.fork()`
harness driving `container exec -it s3-probe sh` and separate direct
`container exec` probes):**

1. **TTY allocation, colors, resize, ctrl-c, line editing all pass.**
   `container exec -it <id> sh` allocates a real PTY inside the container
   (`tty` → `/dev/pts/0`, `test -t 0` succeeds). Raw ANSI escape bytes
   (`\x1b[31mRED\x1b[0m`) survive the round trip unmodified — no stripping
   or translation. `TIOCSWINSZ` on the locally-owned PTY master (no manual
   `SIGWINCH` send needed) propagates correctly — `stty size` inside the
   container reflects the exact new rows/cols. Writing `0x03` to the master
   interrupts a foreground `sleep` (confirmed via exit code 130 = 128+SIGINT,
   not just a local `^C` echo). Backspace works in cooked mode (standard
   `\b ESC[J` erase-and-redraw per character).

2. **`-i` and `-t` are both required, and mean different things.** `-t`
   alone allocates the PTY (`test -t 0` succeeds); `-i` alone does not.
   Neither flag → not a tty. This matches Docker's `-it` convention exactly.
   Also: **exec's stdio must be a real PTY**, not just any pipe — driving
   `-it` through a plain `subprocess.Popen` pipe (no PTY) fails immediately,
   client-side, with `Error: failed to exec process ...
   Code=25 "Inappropriate ioctl for device"`.

3. **Shell inventory (grounds P1C's sh→bash→ash detection order):**
   `alpine:latest` has `/bin/sh` and `/bin/ash` (both the same busybox
   multi-call binary via `readlink -f /bin/sh` → `/bin/busybox`), **no
   `bash`, no `dash`**. `debian:latest` has `/bin/sh` (→ `dash`), `/bin/bash`,
   `/bin/dash`, **no `ash`**. Both images have `/bin/sh` at minimum, so `sh`
   connects in practice on both; `bash`/`ash` are fallbacks for images
   lacking `sh` (not observed in this spike).

4. **MAJOR — the local `container exec -it` client process does not respond
   to SIGTERM or SIGINT at all.** Sent each, polled `waitpid` for 10s and 5s
   respectively — the process never exited on its own either time. This is
   the opposite of `container build` (S5: SIGINT/SIGTERM both handled inside
   1s). Only **SIGKILL** ends the local client, and it does so immediately.

5. **MAJOR — SIGKILLing the local exec client does not tear down the
   container-side process, unlike `build`'s buildkit session.** A foreground
   `sleep 60` exec'd via `-it`, whose local client was then SIGKILLed, was
   confirmed still running inside the container (`container exec <id> sh -c
   'ps aux'`) well after the local client was gone — reproduced across two
   trials (SIGTERM-then-SIGKILL and SIGINT-then-SIGKILL). S5's finding that
   the builder's gRPC/vsock session tears down automatically on client
   disconnect **does not generalize to exec sessions**.

6. **However, stopping the container itself while an exec session is
   attached cleans up perfectly.** `container stop <id>` while `-it` is
   attached causes the local client to detect the disconnect and exit **on
   its own**, sub-100ms, with exit code `137` (128+SIGKILL, the conventional
   "container was killed out from under you" code). No local hang, and the
   container-side orphan question is moot since the whole VM (and every
   process in it) is torn down with the container.

7. Exit-code propagation for interactive `exec -it` matches the
   non-interactive case already documented in
   `2026-07-13-p1a-implementation-notes.md`: `sh -c 'exit 42'` → CLI process
   exits `42` exactly.

**Consequence:**

- P1C's `PTYExecSession` (TerminalKit) **owns the PTY directly**
  (`posix_openpt`/`forkpty`) and drives SwiftTerm's `feed(byteArray:)` —
  it does **not** use SwiftTerm's `LocalProcess`. SwiftTerm's `LocalProcess`
  wants to own the child process lifecycle itself, which conflicts with
  AGENTS.md rule 3's subprocess discipline (typed errors, explicit
  cancellation contract already living in `Subprocess`) and with keeping
  `TerminalSession` fake-able in tests per rule 2. This also matches the
  existing protocol doc-comment in `Sources/TerminalKit/TerminalKit.swift`.
- `PTYExecSession.terminate()` **must shut down over the PTY byte stream**
  (write Ctrl-C `0x03` to interrupt any foreground command, then `exit\n` or
  EOF to end the shell, bounded by a short grace period observing the local
  client's own process exit) — **not** by sending process signals to the
  local `container exec -it` client, since SIGTERM/SIGINT are no-ops there.
  SIGKILL is an acceptable last-resort fallback for releasing local
  resources, but is a known, narrow gap: it can orphan a container-side
  process if a foreground command is running and the container itself keeps
  running afterward. This only bites "force-close a tab mid hung-command";
  the orphan disappears the moment that container stops or is deleted.
- `PTYExecSession` should treat the local client's own unprompted exit
  (particularly exit code 137) as the "container stopped externally" signal
  and surface an "exited" state rather than an error — this is the clean,
  already-working path for the P1C deliverable "container stops → session
  shows a clear exited state, no zombie processes."
- Shell detection order **sh → bash → ash** (master plan §3, unchanged) is
  grounded: alpine (sh/ash, no bash), debian (sh/bash/dash, no ash).
- Resize: `resize(columns:rows:)` issues `TIOCSWINSZ` on the master fd
  `PTYExecSession` owns; no explicit `SIGWINCH` forwarding needed — the
  kernel + `container exec -it` handle propagation automatically (verified,
  not assumed).
- `exec -it` requires **both** `-i` and `-t` flags and a real PTY for stdio
  — `PTYExecSession` must allocate one, not wire up plain pipes.

**Falsifiability note:** re-verify the SIGTERM/SIGINT-ignored and
SIGKILL-orphans-container-side-process findings (points 4–5) against future
`container` CLI versions — this is exec-client-specific behavior (distinct
from `build`'s client, which does handle these signals per S5) and could
change if a later `container` version adds signal handling to its exec
client or teardown-on-disconnect semantics to its exec sessions.
