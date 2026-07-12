# `StatsSample.cpuUsageMicroseconds` (`cpuUsageUsec`) semantics: cumulative, not a rate

**Context:** P1B B2+B3 (`ContainerDetailStore`'s stats sparkline) needed to
derive a CPU% for the chart from consecutive `StatsSample` ticks. The field's
doc comment flagged this as unverified — "cumulative-monotonic vs
pre-computed rate" — and asked for two live `stats` ticks on a scratch
container to settle it before implementing the derivation.

**Finding — confirmed cumulative (monotonically increasing total microseconds
of CPU time consumed since container start), analogous to the Linux cgroup
`cpuacct.usage`/`cpu.stat` `usage_usec` counter:**

Ran a CPU-pegging scratch container (`container` CLI 1.1.0, macOS 26.1) —
`alpine sh -c 'i=0; while true; do i=$((i+1)); done'`, a tight single-threaded
busy loop expected to consume ~100% of one core — and sampled
`container stats --no-stream --format json capsule-cpu-probe` three times,
~7s apart, recording wall-clock time immediately before each call:

| wall time (unix, `date +%s.%N`) | `cpuUsageUsec` |
|---|---|
| 1783896875.573772 | 7918203 |
| 1783896882.635045 | 15082113 |
| 1783896889.795888 | 22206046 |

Deltas:
- Tick 1→2: wall elapsed 7.0613s, `cpuUsageUsec` delta 7,163,910 usec = 7.16391s
  of CPU consumed → **101.5%** of one core.
- Tick 2→3: wall elapsed 7.1608s, `cpuUsageUsec` delta 7,123,933 usec =
  7.123933s of CPU consumed → **99.5%** of one core.

Both are ~100% of one core, exactly matching the busy-loop workload, and the
raw value **strictly and monotonically increases** tick over tick rather than
fluctuating around a steady-state number the way a pre-computed instantaneous
rate would. That rules out "already a rate" and confirms "cumulative counter
since container start."

**Consequence — the derivation implemented in
`ContainerDetailStore.cpuPercent(current:previous:)`
(`Sources/AppCore/ContainerDetailStore.swift`):**

```
cpuPercent = ((current.cpuUsageMicroseconds - previous.cpuUsageMicroseconds) / 1_000_000)
           / elapsedWallSeconds * 100
```

expressed as "percent of one CPU core" (so a fully-pegged 4-core container
doing parallel work can read up to ~400%, matching Activity Monitor's
per-process convention, not Docker's `nproc`-normalized single-100%-cap
convention). `elapsedWallSeconds` comes from wall-clock receipt timestamps the
store itself attaches to each tick (`StatsSample` carries no timestamp of its
own) — **not** the nominal `statsInterval`, since the real cadence is ~4.2s
per [`2026-07-13-stats-polling-cost.md`](2026-07-13-stats-polling-cost.md),
not the 2s configured interval. Guarded against a negative delta (counter
reset, e.g. container restarted between ticks) and a zero/negative elapsed
time — both return `nil` (no plotted point) rather than a nonsensical
negative or infinite percentage.

**Environment note:** the S4 stats-cost note's zsh word-splitting caveat
applies again here — `container stats --no-stream --format json <name>` takes
the container name as a plain trailing argument, no quoting surprises this
time since only one id was passed.
