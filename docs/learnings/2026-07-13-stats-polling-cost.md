# Stats polling cost

**Context:** S4 spike (stats streaming cost, trimmed scope) — P1A's
implementation spike already established `container stats --format json`'s
streaming mode is a dead end (one array then silent) and that
`CLIProcessClient.stats(ids:)` polls `--no-stream` on a `statsInterval`
(default 2s) instead. This note captures the measured cost of that
`--no-stream` call, used to ground P1B's Containers-screen sparkline cadence.

**Finding — `container stats --no-stream --format json` has a fixed ~2.2s
wall-clock floor, independent of N:**

| N (container ids requested) | Wall (real) | Client CPU (user+sys) |
|---|---|---|
| 1 | ~2.17–2.20s | ~0.03s |
| 5 | ~2.25–2.29s | ~0.02–0.03s |
| 10 | ~2.38–2.42s | ~0.02–0.03s |

Measured on `container` CLI version 1.1.0, `/usr/bin/time -l`, 3 timed runs
per N after a discarded warm-up, against idle `sleep 3600` alpine containers
(macOS 26 host). Full verbatim output in
[`docs/spikes/S4-stats-cost.md`](../spikes/S4-stats-cost.md).

Contrast with `container ls --all --format json` (the existing
`RuntimePoller`'s call): consistently **~0.02s** regardless of container
count.

**Consequence:** the ~2.2s cost is a **fixed round-trip latency floor, not
per-container work** (going 1→10 containers added only ~0.2s, ~0.02s/id) and
**not CPU load** — client CPU stayed at ~20-30ms and `container-apiserver`'s
CPU% measured 0.0% via `top -l 3 -pid <pid>` across three 1s samples during a
sustained back-to-back (no-sleep) polling loop of N=10 calls. Working
hypothesis (unconfirmed against runtime source, falsifiable): the stats
collector samples cgroup/VM counters on its own internal ~1-2s tick to
compute rate-based fields (`cpuUsageUsec`, `networkRxBytes`/`TxBytes` deltas),
and `--no-stream` blocks for at least one such tick rather than returning an
already-resident value — unlike `ls`, which reads a live in-memory registry.
Re-verify this latency figure if a future `container` version is suspected to
change stats internals.

Because the call+sleep pattern in `CLIProcessClient.stats(ids:)`
(`Sources/ContainerClient/CLIProcessClient.swift:168-216`) awaits the call
*then* sleeps `interval`, **the real update period at the 2s default is
~4.2s (≈2.2s call + 2s sleep), not 2s** — `statsInterval` is "minimum gap
after the previous call completes," not "calls per second." Worth a doc-
comment clarification when P1B touches this code, not a behavior change.

**Recommendation for P1B (Containers-screen sparklines):**
1. Keep the 2s `statsInterval` default — the ~4.2s effective cadence it
   produces is fine for CPU/mem sparklines; no per-N reduction needed since
   cost doesn't scale with N.
2. **Pause the stats poll when the sparkline UI isn't visible** (stop
   consuming the stream / let it get cancelled on navigate-away or window
   background, resume on return) — not because of measured CPU cost (which
   is negligible either way) but because there's no payoff running it
   unwatched, and it's one fewer live background subprocess-spawning `Task`.
   `stats(ids:)`'s `continuation.onTermination` already cancels the poll
   loop, so this needs no new API — just disciplined start/stop from the
   ViewModel.
3. **No dedicated stats actor needed.** `stats(ids:)` is already
   tick-batched and independently cancellable; P1B should be a thin
   ViewModel adapter over the existing stream, not a new CapsuleKit type. The
   only "adaptive" lever stats needs (visibility) belongs in the UI
   consumption layer, not a new engine-side backoff state machine like
   `RuntimePoller`'s idle/unavailable tiers (those exist for a different
   reason — detecting *unchanged container-list* ticks — that doesn't apply
   to stats).
4. **No contention concern with `RuntimePoller`'s `ls` poll at N=10.**
   `ls --all --format json` is ~0.02s vs. stats' ~2.2s+ — two orders of
   magnitude apart — and both are latency-bound, not CPU-bound; apiserver
   CPU stayed at 0.0% under a stats-only tight loop far more aggressive than
   any real dual-poll scenario. The two polls don't need to share a cadence
   or be staggered.

**Environment nuance also surfaced:** the working shell is `zsh`, which does
**not** word-split an unquoted variable expansion the way `bash` does — an
unquoted multi-line `IDS=$(...)` variable was passed as one argument
containing embedded newlines rather than N separate `stats` arguments,
producing a confusing `no such container: s4-c1\ns4-c2\n...` error before the
fix (`${=IDS}` after building a space-joined string). Not a `container` CLI
behavior — purely a zsh-vs-bash scripting gotcha, recorded here since it cost
debugging time and will recur for any future spike/ops script invoking
`container` with a variadic id list from zsh.
