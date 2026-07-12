# P0 — Spikes

Five independent, time-boxed (≤1 day each) experiments. Each spike can be its
own worktree/agent; they produce **documents and decisions, not production
code** (implementation belongs to the owning package). All five can run in
parallel; S1 is the highest-risk and should start first.

| | |
|---|---|
| Branches | `phase/p0-s1-dns` … `phase/p0-s5-build-cancel` |
| Depends on | nothing (S2 partially seeded already) |
| Blocks | S1→P2A discovery tasks · S2→P1A model tightening · S3→P1C · S4→P1B stats UI · S5→P1A subprocess hardening |
| Owns | `docs/spikes/S<n>-*.md`, new `docs/learnings/` notes |

**Read first:** `AGENTS.md`; master plan §4.4 (S1), §2.2 (S2), §3 (S3/S4),
§5 risks; `docs/spikes/README.md` (format); both existing learnings notes.

**Deliverable per spike:** `docs/spikes/S<n>-<topic>.md` with Question /
Method (exact commands) / Result (raw output excerpts) / Decision. Update the
spike table in `docs/spikes/README.md`, tick the ROADMAP box, and put durable
facts in `docs/learnings/` per the learning loop. Clean up every container/
volume/network you create (`s<n>-` name prefix, delete on exit).

---

## S1 — DNS / service discovery (decides master plan §4.4)

**Question:** on macOS 26 with `container` 1.1.x, can container B reach
container A by bare name (`http://a/`), and if not, which of the §4.4 options
(search domains → hosts injection → DNS proxy) is the cheapest that works?

Method sketch (adapt as results dictate, record everything):

```sh
container network create s1net
container run -d --name s1-web --network s1net docker.io/library/nginx:latest
container run -d --name s1-probe --network s1net docker.io/library/alpine:latest sleep 3600
container exec s1-probe cat /etc/resolv.conf
container exec s1-probe nslookup s1-web        # bare name?
container exec s1-probe wget -qO- --timeout=3 http://s1-web/ && echo BARE-NAME-WORKS
# also try: default network instead of s1net; FQDN forms nslookup suggests;
# --dns-search / --dns-domain flags on `container run`;
# `sudo container system dns create s1test` + rerun (document the sudo need).
```

**Decision to record:** which discovery mechanism P2A implements, exactly what
flags/labels each `container run` needs, and what `capsule compose config
--report` must print about name resolution.

## S2 — `--format json` coverage (complete the seeded findings)

**Question:** exact JSON shape of `container list`, `inspect`, `volume ls`,
`network ls`, `image inspect`, `stats`, `system df` with real resources
present — and which commands *lack* `--format json`.

```sh
container run -d --name s2-probe -p 8099:80 docker.io/library/nginx:latest
container list --all --format json    # THE gap: ContainerSummary is unverified
container inspect s2-probe            # ports, networks, labels shape
container volume create s2-vol && container volume ls --format json
container network ls --format json
container system status --format json 2>&1   # does it exist?
```

**Decision to record:** captured JSON samples (verbatim, into the learnings
note), the list of table-only commands, and which `ContainerSummary`/future
DTO fields P1A must fix or tighten. Update
`docs/learnings/2026-07-12-runtime-cli-observations.md` in place.

## S3 — PTY/exec interactive quality

**Question:** is SwiftTerm over `container exec -it` good enough for the
terminal screen (resize propagation, colors, ctrl-c, line editing)?
Method: minimal throwaway harness (scratch dir or `docs/spikes/s3-harness/`,
never `Sources/`) driving `container exec -it s3-probe sh` under a PTY
(`posix_openpt`/`forkpty` or SwiftTerm's `LocalProcess`). Score each behavior.
**Decision:** SwiftTerm viable? Which PTY-spawn path does P1C use? Shell
detection order (sh/bash/ash) confirmed?

## S4 — stats streaming cost

**Question:** `container stats` output format (JSON?), whether it streams or
snapshots, and the CPU cost of polling 10 containers at 1s/2s intervals.
Method: run 10 alpine containers in a loop, sample `container stats`
variants, measure with `/usr/bin/time` and Activity Monitor.
**Decision:** polling cadence + parsing strategy for P1B sparklines; whether
stats need their own actor with adaptive backoff.

## S5 — build streaming + cancellation

**Question:** SIGINT/SIGTERM semantics of `container build` — does
cancellation leave the builder consistent? Does `Subprocess`'s SIGTERM-only
`terminate()` suffice or is SIGKILL escalation required (existing TODO in
`Subprocess.swift`)?
Method: trivial Dockerfile with a slow `RUN sleep` layer; interrupt at
various points; inspect `container builder status` afterwards.
**Decision:** the exact cancellation contract P1A implements in `Subprocess`
(grace period, escalation, builder-state caveats for the UI).
