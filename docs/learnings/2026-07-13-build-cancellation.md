# `container build` cancellation semantics

**Context:** S5 spike (`docs/spikes/S5-build-cancel.md`) — informing the
`Subprocess.swift:61-64` TODO ("escalate SIGTERM → SIGKILL if the process
ignores `terminate()`") ahead of the P1A implementation PR wiring
build/streaming into `ContainerRuntime`.

**Finding (container CLI 1.1.0, `container build`):**

- The builder is a separate, persistent subsystem (`buildkit` container,
  image `ghcr.io/apple/container-builder-shim/builder:0.12.0`, running
  `buildkitd` + a shim under vsock). `container build` **auto-starts** it if
  not already running — no explicit `container builder start` is required.
  `container builder status` prints the plain string `builder is not running`
  when no builder container exists at all; once one has ever been created it
  instead prints a table with a `STATE` column (`running`/`stopped`) — these
  are two different reportable states, not synonyms. `container builder stop`
  only gets you to the `stopped` table row; `container builder delete
  [--force]` is required to get back to the "no container" / "builder is not
  running" state.
- `container build` installs its own signal handler for both **SIGINT** and
  **SIGTERM**: on receipt it prints `Error: interrupted: "exiting on signal
  <N>"` (2 for INT, 15 for TERM) to stderr and exits in well under 1 second,
  every time observed, including mid-`RUN` (tested against a `RUN sleep 120`
  layer). No difference in behavior or timing was found between SIGINT and
  SIGTERM.
- **SIGKILL** of the `container build` client process (bypassing its handler
  entirely) does **not** leave an orphaned build running inside the builder
  VM. `container exec buildkit ps aux` immediately after a SIGKILL showed
  only `container-builder-shim` and `buildkitd` — no lingering `sleep`
  process from the killed build's `RUN` step. A follow-up build issued
  immediately after completed in ~0.15s (cached) with no queuing/contention,
  confirming the builder was not exclusively locked by the killed session.
  Mechanism (inferred, not directly logged — `container system logs` at
  Info/Error level shows builder-startup/network detail but nothing
  build-session-specific): the builder-side gRPC/vsock session appears to be
  torn down when the client's connection drops, which happens automatically
  at the OS level even under SIGKILL (fd closure), so the builder cancels the
  in-flight step server-side without needing the client to signal intent.
- `--progress plain` output is line-oriented, `\n`-terminated, and free of
  ANSI escapes/carriage returns — one build step or status transition per
  line (e.g. `#5 [linux/arm64 1/2] RUN sleep 120`, `#5 DONE 0.1s`). Verified
  with `od -c` and a `\r` grep (both zero). `--progress auto`, when stdout is
  a non-tty pipe (always true for `Subprocess`'s `Pipe`), was observed to
  render identically to `plain` in this version — but pin `plain` explicitly
  rather than relying on `auto`'s tty-detection remaining stable across CLI
  updates.

**Consequence:**

- P1A's `Subprocess` cancellation path should send `terminate()` (SIGTERM),
  wait a **5-second grace period**, then `SIGKILL` if still running. This is
  a **general defense-in-depth contract for all `Subprocess`-spawned
  children** (safe to apply uniformly — nothing about `build` specifically
  needed it in testing), not evidence of an observed `build`-specific hang.
  SIGTERM alone was sufficient in every `build` trial in this spike.
- P1A's build-streaming implementation should invoke `container build
  --progress plain …` explicitly and parse stdout line-by-line via
  `FileHandle.bytes → AsyncThrowingStream` (or the pipe-based equivalent
  `Subprocess` already uses for buffered output) — no ANSI/carriage-return
  handling needed.
- The Builds screen does **not** need a mandatory "builder is broken, you
  must reset it" warning after every cancel — the builder was never observed
  to wedge in this spike, across SIGINT/SIGTERM/SIGKILL. A defensive "Reset
  Builder" affordance (calling `container builder stop`+`start`, or `delete`
  and letting the next build auto-recreate it) is still worth adding as cheap
  insurance for failure modes this spike didn't exercise (e.g. a kill during
  layer export or registry push), documented as precautionary, not
  load-bearing.
- If code or docs need to distinguish "no builder container" from "builder
  container present but stopped," use `container builder delete [--force]`
  to reach the former — `stop` alone leaves the latter.

**Falsifiability note:** re-verify against future `container` CLI versions —
the "no orphan on SIGKILL" finding depends on the builder's session-teardown
behavior on client disconnect, which is an implementation detail of
`buildkitd`/the shim that could change. Re-run the SIGKILL trial (§4 of the
spike doc) if `container --version` moves past 1.1.0 before this contract
ships.
