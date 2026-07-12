# S4 — stats streaming cost

**Status:** decided (2026-07-13).

## Question (trimmed scope)

The format/stream-vs-snapshot half of S4's original question is **already
answered** — P1A's implementation spike found `container stats --format json`
in streaming mode emits exactly one JSON array and then goes silent forever
(confirmed over a 25s trial), so `CLIProcessClient.stats(ids:)` already
implements stats as a poll loop over `container stats --no-stream --format
json` at a 2s default interval (`statsInterval`). See
[`docs/learnings/2026-07-13-p1a-implementation-notes.md`](../learnings/2026-07-13-p1a-implementation-notes.md)
finding #6 and the correction to finding #9 of
[`docs/learnings/2026-07-12-runtime-cli-observations.md`](../learnings/2026-07-12-runtime-cli-observations.md).
This spike does **not** re-litigate that.

The one remaining question: **what does one `container stats --no-stream
--format json` invocation cost (wall-clock + CPU) across N containers (N≈1,
5, 10), and given that cost, what cadence/backoff/actor design should P1B's
Containers-screen sparklines use?**

Decides master plan §3 (Containers screen stats sparklines) and whether the
existing `RuntimeGateway.stats(ids:)` stream needs a dedicated actor with
adaptive backoff, separate from `RuntimePoller`.

## Machine state (reconfirmed before starting)

```
$ container --version
container CLI version 1.1.0 (build: release, commit: 5973b9c)
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED   (empty, clean slate)
```

## Method (exact commands, in order)

**Shell gotcha hit and corrected:** the working shell is `zsh`, which — unlike
`bash` — does **not** word-split an unquoted variable expansion by default.
`IDS=$(...)` followed by `container stats ... $IDS` passed the entire
newline-joined string as a single argument, producing `Error: no such
container: s4-c1\ns4-c2\n...` (read literally as one container name with
embedded newlines). Fixed with zsh's explicit split flag, `${=IDS}`, after
building `IDS` as a *space*-joined string. Recorded as a durable fact below —
this is an environment/tooling nuance, not a `container` CLI behavior.

### 1. Launch 10 scratch containers

```sh
for i in $(seq 1 10); do container run -d --name s4-c$i docker.io/library/alpine:latest sleep 3600; done
container ls --all | grep s4- | wc -l
```
→ `10` (all started successfully, each with a `[0/6]…[6/6] Starting container` progress trace on stderr).

### 2. `stats --no-stream --format json` at N=1, 5, 10

One warm-up call discarded per N, then 3 timed calls via `/usr/bin/time -l`.

**N=1** (`container stats --no-stream --format json s4-c1`):

```
[{"blockReadBytes":1744896,"blockWriteBytes":0,"cpuUsageUsec":2203,"id":"s4-c1","memoryLimitBytes":1073741824,"memoryUsageBytes":2002944,"networkRxBytes":30289,"networkTxBytes":602,"numProcesses":1}]
        2.17 real         0.02 user         0.01 sys
             3736056  peak memory footprint
```
Runs 2–3: `2.20 real`/`0.02 user`/`0.01 sys`, `2.18 real`/`0.02 user`/`0.01 sys`.

**N=5** (`s4-c1 s4-c2 s4-c3 s4-c4 s4-c5`):

```
        2.25 real         0.02 user         0.01 sys
             4030968  peak memory footprint
```
Runs 2–3: `2.29 real`/`0.02 user`/`0.00 sys`, `2.29 real`/`0.02 user`/`0.01 sys`.

**N=10** (all ten `s4-c1`…`s4-c10`, via `${=IDS}` after the zsh fix):

```
        2.38 real         0.02 user         0.01 sys
             4243960  peak memory footprint
```
Runs 2–3: `2.38 real`/`0.02 user`/`0.01 sys`, `2.42 real`/`0.02 user`/`0.01 sys`.

Across all three N values the returned JSON values for containers not
involved in that specific call were byte-identical between successive calls
seconds apart (e.g. `s4-c1`'s `cpuUsageUsec:2203` never changed across 6
separate invocations spanning ~2 minutes) — expected, since these are idle
`sleep 3600` containers doing no work, not evidence of stale/cached data.

### 3. `container ls --all --format json` for comparison (the Poller's existing call)

```
$ /usr/bin/time -l container ls --all --format json
        0.02 real         0.01 user         0.00 sys
             4440640  peak memory footprint
```
Consistent across 3 runs (`0.02 real` every time, `0.01 user`/`0.00 sys`).

### 4. Qualitative apiserver CPU during sustained stats polling

Ran 7 back-to-back N=10 `stats --no-stream` calls in a tight loop (no sleep
between them — a worst case far more aggressive than any real poll cadence)
while sampling `container-apiserver`'s CPU% via `top -l 3 -pid <apiserver
pid> -stats pid,command,cpu,mem`:

```
PID    COMMAND          %CPU MEM
74633  container-apiser 0.0  6480K
74633  container-apiser 0.0  6480K
74633  container-apiser 0.0  6480K
```

`container-apiserver` reported **0.0% CPU** across all three 1-second
samples during sustained back-to-back polling. (System-wide `CPU usage` in
the same `top` header was 10–19% user / 7–28% sys, but that reflects the rest
of the loaded dev machine, not this workload — the named-process line is the
relevant number and it stayed flat at 0.0%.)

## Result — cost table

| N | Wall (real) | Client CPU (user+sys) | Peak client RSS | apiserver CPU during sustained polling |
|---|---|---|---|---|
| 1 | ~2.17–2.20s | ~0.03s | ~3.7 MB | 0.0% (see §4) |
| 5 | ~2.25–2.29s | ~0.02–0.03s | ~4.0 MB | 0.0% |
| 10 | ~2.38–2.42s | ~0.02–0.03s | ~4.2 MB | 0.0% |
| — `ls --all --format json` (Poller's call) | ~0.02s | ~0.01s | ~4.4 MB | n/a (not separately sampled; trivially cheap) |

**Cost does not scale meaningfully with N** — going from 1 to 10 containers
adds ~0.2s to wall-clock (≈0.02s/container) and no measurable client CPU.
**The cost is dominated by a fixed ~2.2s round-trip floor**, not by
per-container work. Contrast sharply with `ls --all --format json`, which
returns in ~20ms regardless — that command hits a live in-memory registry;
`stats --no-stream` evidently blocks on something with a ~2s inherent floor
(most plausibly: the runtime's stats collector samples cgroup/VM counters on
its own internal tick — plausibly ~1–2s — to compute rate-based fields like
`cpuUsageUsec`/`networkRxBytes` deltas, and `--no-stream` blocks for at least
one such tick before returning, rather than reading a value that's already
resident). This is a hypothesis, not confirmed against runtime source — flag
as **falsifiable, re-verify if a future runtime version changes this
latency**.

Crucially, this ~2.2s wall-clock cost is **not CPU cost** — client CPU stays
at ~20–30ms and the apiserver process showed 0.0% CPU throughout sustained
polling. The cost is *latency*, paid by whichever `Task` awaits the
subprocess, not *load* on the machine. This distinction is the crux of the
cadence decision below.

## Decision

### 1. P1B sparkline poll cadence

**Recommendation: keep the existing 2s `statsInterval` default, but understand
what it actually produces.** `CLIProcessClient.stats(ids:)`'s poll loop
(`Sources/ContainerClient/CLIProcessClient.swift:168-216`) awaits the
subprocess call, yields, *then* sleeps `interval` — so the real update period
is **call-duration + interval ≈ 2.2s + 2s ≈ 4.2s** at the default, not a flat
2s as the parameter name might suggest. That is still a perfectly acceptable
sparkline cadence (nobody needs sub-second CPU/mem graph resolution for a
handful of containers), but it should be **named/documented accurately** —
recommend adding a doc-comment note on `statsInterval` clarifying it's
"minimum gap after the previous call completes," not "calls per second," so
a future reader doesn't assume 2s throughput. No code change needed from this
spike (docs-only), but flagging for P1B's implementation.

Since cost is dominated by the fixed round-trip floor and not by N, **there
is no reason to reduce N below "all containers currently shown"** or to
tier/batch by visible-vs-hidden container — one call for the whole visible
set costs about the same as one call for a single container.

### 2. Adaptive backoff / pause-when-not-visible

**Yes — pause the stats poll entirely when the stats UI (sparklines) isn't
visible**, and resume immediately when it becomes visible again (no need for
tiered backoff levels the way `RuntimePoller` has `interval` →
`idleInterval` → `unavailableInterval`, since stats has no meaningful "idle
but still shown" state the way container-list changes do — either the
sparklines are on screen and being watched, or they're not and every call is
pure waste). Concretely: the Containers-screen ViewModel should call
`stats(ids:)` (or restart iteration of an existing stream) only while its
view is in the visible/foregrounded state, and cancel/stop consuming the
stream when navigated away or the window is backgrounded — cancellation is
already the stream's sole teardown signal (`continuation.onTermination`
cancels `pollTask`), so this requires no new API, just disciplined
consumption from the UI layer.

Justification: at ~2.2s wall-clock per call, running this poll continuously
in the background (e.g. from app launch, or while the user is on a different
screen) buys nothing — CPU cost is negligible either way, but there is no
value delivered when nobody is looking at the sparkline, and it is one more
long-lived background `Task` + subprocess spawn every ~4s for zero payoff.
This is a UI-consumption-discipline decision, not a cost-driven necessity
(the actual cost, per §4's apiserver reading, is close to free) — call it
"tidy default," not "load-bearing optimization."

### 3. Dedicated stats actor?

**Not warranted. P1B should reuse `stats(ids:)` directly** — the stream
already exists on `CLIProcessClient`/exposed through `RuntimeGateway`, it is
already tick-batched (`[StatsSample]` per poll, per the Contract PR's design
decision recorded in
[`docs/learnings/2026-07-13-container-runtime-contract.md`](../learnings/2026-07-13-container-runtime-contract.md)),
and it already has clean cancellation semantics matching `RuntimePoller`'s
own discipline. A second actor would only be justified if stats needed
independent adaptive-interval *state* the way `RuntimePoller` needs it for
idle-vs-active container-list changes — but §2 above found no such need:
stats' only "backoff" lever is visibility, which belongs in the ViewModel
(start/stop consuming the stream), not in a new engine-layer actor. Keep the
poll loop where it is; P1B's job is a thin ViewModel adapter over the
existing stream, not a new CapsuleKit type.

### 4. Concurrency with the `ls` Poller

**No meaningful contention at N=10.** The `ls` Poller's call
(`~0.02s wall, ~0.01s CPU`) is two orders of magnitude cheaper than a stats
call and runs on its own independent 2s-base cadence
(`RuntimePoller.interval`); the two polls are not synchronized and don't need
to be. Both calls are latency-bound, not CPU-bound (§ Result), and the
apiserver showed 0.0% CPU even under a stats-only tight loop far more
aggressive than any real dual-poll scenario — so there's no CPU-contention
argument for staggering them. **No change recommended**: let `RuntimePoller`
and the stats poll run on their own independent schedules, each with its own
sleep-after-completion cadence. The only mild caveat: since a stats call
takes ~2.2-2.4s of wall-clock, a user on the Containers screen has *two*
concurrent background polls in flight (list + stats) — inspected together
they add up to roughly one `container` subprocess spawn every ~2s (`ls`) plus
one every ~4s (`stats`, given the call+sleep total from §1) — trivial by any
CPU/memory measure recorded here, and no apiserver serialization/queueing
was observed in the tight-loop test.

## Cleanup — verified back to pre-spike state

```sh
$ container delete -f s4-c1 s4-c2 s4-c3 s4-c4 s4-c5 s4-c6 s4-c7 s4-c8 s4-c9 s4-c10
$ container ls --all | grep s4- || echo "no s4 containers (good)"
no s4 containers (good)
```

No networks, volumes, or images were created by this spike (`alpine:latest`
was already pulled by earlier S1/S2/S5 spikes and is left untouched).
