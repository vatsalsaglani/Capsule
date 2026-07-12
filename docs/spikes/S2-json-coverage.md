# S2 — `--format json` coverage

**Status:** decided (2026-07-13) — fully verified with a populated runtime.

## Question

Exact JSON shape of `container list`, `inspect`, `volume ls`, `network ls`,
`image inspect`, `stats`, `system df` with real resources present — and which
commands *lack* `--format json`. Completes the seeded findings in
`docs/learnings/2026-07-12-runtime-cli-observations.md` (finding #3: the
populated `container list` shape was the known gap).

## Machine state (reconfirmed before starting)

```
$ container --version
container CLI version 1.1.0 (build: release, commit: 5973b9c)
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED
$ container volume ls
NAME  TYPE  DRIVER  OPTIONS
$ container network ls
NETWORK  SUBNET
default  192.168.64.0/24
$ container image ls
NAME    TAG     DIGEST
alpine  latest  28bd5fe8b56d
nginx   latest  ec4ed8b5299e
```

Clean slate confirmed (nginx already present locally from the S1 spike —
no new pull needed for this session).

## Method (exact commands, in order)

### 1. `container list` — THE gap

```sh
container run -d --name s2-probe -p 8099:80 docker.io/library/nginx:latest
container list --all --format json
```

Full populated shape captured verbatim — see
[learnings finding #3](../learnings/2026-07-12-runtime-cli-observations.md)
for the complete JSON (reproduced in full there, not duplicated here to
avoid drift between two copies). Headline facts:

- `configuration.publishedPorts[]` — `{containerPort, count, hostAddress,
  hostPort, proto}` — ports live here, not under `status`.
- `configuration.labels` — flat `[String: String]`.
- `status.networks[].ipv4Address` — CIDR-form resolved IP (e.g.
  `"192.168.64.6/24"`); `configuration.networks[]` is only the *requested*
  attachment (no address).
- `status.state` — the actual run-state string (`"running"`/`"stopped"`);
  there is **no top-level `status` string** and **no top-level `networks`
  key** — both only exist nested.

### 2. `container inspect` — cross-check vs S1, and does `--format` work?

```
$ container inspect s2-probe
[ ... same configuration/status shape as `list`, single-element array ... ]

$ container inspect s2-probe --format json
Error: Unknown option '--format'
Usage: container inspect [--debug] <container-ids> ...

$ container inspect --help
OPTIONS:
  --debug                 Enable debug output [environment: CONTAINER_DEBUG]
  --version               Show the version.
  -h, --help              Show help information.
```

**`inspect` has no `--format` flag at all** — it always emits pretty-printed
JSON unconditionally (2-space indent, spaces around `:`; same schema as
`list`'s compact JSON). Passing `--format json` is a hard CLI usage error
(exit 64), not a silent no-op. Confirmed identical to the S1 `container
inspect s1-web` capture — `inspect` and `list` share one schema.

### 3. Volumes

```
$ container volume create s2-vol
s2-vol

$ container volume ls --format json
[{"configuration":{"creationDate":"2026-07-12T20:25:40Z","driver":"local","format":"ext4","labels":{},"name":"s2-vol","options":{},"sizeInBytes":549755813888,"source":"/Users/.../volumes/s2-vol/volume.img"},"id":"s2-vol"}]

$ container volume inspect s2-vol --format json
Error: Unknown option '--format'
Usage: container volume inspect [--debug] <names> ...

$ container volume inspect s2-vol
[ { "configuration" : { ...same fields as ls, single object... }, "id" : "s2-vol" } ]
```

Same `inspect`-has-no-`--format` pattern as containers. `volume ls
--format json` works and matches the `list`/`image list` schema family
(`configuration` + `id`).

### 4. Networks

```
$ container network ls --format json
[{"configuration":{"creationDate":"2026-07-12T12:21:18Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd2e:2a8d:ce3a:268b::/64"}}]

$ container network inspect default --format json
Error: Unknown option '--format'
Usage: container network inspect <networks> ... [--debug]

$ container network inspect default
[ { "configuration" : { ...same fields... }, "id" : "default", "status" : {...} } ]
```

Note: the built-in `default` network carries its own label
(`com.apple.container.resource.role: builtin`) — distinct from any
`capsule.*` label the compose engine would set on project-created networks;
don't confuse the two when filtering by label.

### 5. Images (reconfirm the seeded shape)

```
$ container image list --format json
[ ...alpine entry..., ...nginx entry... ]   # full OCI image-config-spec
                                             # nested under variants[].config
                                             # (history, rootfs diff_ids,
                                             # per-platform digests)

$ container image inspect docker.io/library/nginx:latest --format json
Error: Unknown option '--format'
Usage: container image inspect [--debug] <images> ...
```

Confirms the seeded finding #2 (lowerCamelCase, nested `configuration`) with
a real populated multi-image sample instead of a guess. Same
no-`--format`-on-`inspect` pattern, fourth-for-four.

### 6. Stats (light touch — S4 owns depth)

```
$ container stats --help
OPTIONS:
  --format <format>       Format of the output (values: json, table, yaml, toml; default: table)
  --no-stream             Disable streaming stats and only pull the first result

$ container stats --no-stream s2-probe
Container ID  Cpu %  Memory Usage          Net Rx/Tx             Block I/O             Pids
s2-probe      0.00%  26.43 MiB / 1.00 GiB  21.32 KiB / 0.59 KiB  20.54 MiB / 8.00 KiB  6

$ container stats --no-stream --format json s2-probe
[{"blockReadBytes":21536768,"blockWriteBytes":8192,"cpuUsageUsec":19568,"id":"s2-probe","memoryLimitBytes":1073741824,"memoryUsageBytes":27713536,"networkRxBytes":21834,"networkTxBytes":602,"numProcesses":6}]
```

`stats` supports `--format json` and (usefully) a `--no-stream` flag that
avoids needing to interrupt a streaming process just to capture one sample.
JSON is flat, byte/usec units (not the table's human-formatted `"26.43
MiB"` strings) — no unit-string parsing needed once P1B/S4 build on this.
Without `--no-stream` it streams (one array per tick, unbounded) —
characterizing that cost is S4's job; this only confirms shape + one-shot
capture path exists.

### 7. `system df` / `system status`

```
$ container system df
TYPE           TOTAL  ACTIVE  SIZE      RECLAIMABLE
Images         3      1       650.1 MB  323.1 MB (50%)
Containers     1      1       455.1 MB  0 B (0%)
Local Volumes  1      0       69.4 MB   69.4 MB (100%)

$ container system df --format json
{"containers":{"active":1,"reclaimable":0,"sizeInBytes":455069696,"total":1},"images":{"active":1,"reclaimable":323076096,"sizeInBytes":650096640,"total":3},"volumes":{"active":0,"reclaimable":69390336,"sizeInBytes":69390336,"total":1}}

$ container system status --format json
{"apiServerAppName":"container-apiserver","apiServerBuild":"release","apiServerCommit":"5973b9cc626a3e7a499bb316a958237ebe14e2ed","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","appRoot":"/Users/.../Library/Application Support/com.apple.container/","installRoot":"/usr/local/","status":"running"}
```

Both **exist and support `--format json`** — resolving two "does it exist?"
open questions from the seeded findings. `system status --format json` in
particular **corrects** the earlier finding #5 assumption ("no `--format`
flag tested yet") — it does support JSON, so doctor's fragile table-grep for
`running` should switch to decoding `.status == "running"`.

### 8. Labeled container — label shape + list round-trip

```sh
container run -d --name s2-labeled --label capsule.project=demo --label capsule.service=web docker.io/library/nginx:latest
```

```
$ container inspect s2-labeled   # labels land at configuration.labels
"labels" : { "capsule.project" : "demo", "capsule.service" : "web" }

$ container list --all --format json   # confirm labels appear in list, not just inspect
"labels": { "capsule.project": "demo", "capsule.service": "web" }
```

Confirmed: labels round-trip correctly through both `inspect` and `list`,
flat `[String: String]`, no nesting or type coercion surprises — needed for
compose grouping (ComposeRuntime identifies project membership from `list`
output alone, without a per-container `inspect` call).

### Cleanup verification

```sh
container delete -f s2-probe s2-labeled
container volume delete s2-vol
```

```
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED
(empty)
$ container volume ls
NAME  TYPE  DRIVER  OPTIONS
(empty)
$ container network ls
NETWORK  SUBNET
default  192.168.64.0/24
```

Back to baseline (pulled images out of scope, unchanged).

## Table-only commands (no working `--format json`)

**None found.** Every command surveyed either supports `--format json`
(`list`, `volume ls`, `network ls`, `image list`, `stats`, `system df`,
`system status`) or emits JSON unconditionally with no `--format` flag at
all (`container inspect`, `volume inspect`, `network inspect`, `image
inspect`). P1A needs **no table-parser fallback** for anything probed by
S1 or S2. If a future command not covered here (e.g. `container builder
status`, S5's territory) turns out table-only, record it as a new finding
rather than assuming this list is exhaustive.

## Decision

1. **Captured JSON samples:** recorded verbatim above and in
   [learnings finding #3](../learnings/2026-07-12-runtime-cli-observations.md)
   (full `list` shape), findings #5, #7–#10 (system status, inspect-no-format,
   volume/network/image list, stats, system df).

2. **Table-only commands list:** none — see previous section. This
   simplifies P1A: no version-gated table-parser fallback path is needed for
   any surface this spike or S1 touched.

3. **`ContainerSummary` tightening list (the P1A hand-off):** full list with
   rationale lives in the learnings note's "`ContainerSummary` tightening
   list" section (read `Sources/ContainerClient/Models.swift` for this spike,
   not edited — P1A's implementation task). Summary:
   - `status` `CodingKey` currently decodes the wrong type (object, not
     string) — always silently falls back to `"unknown"`.
   - Top-level `networks` `CodingKey` does not exist in real output — always
     silently falls back to `[]`; must decode `status.networks[].ipv4Address`
     instead (CIDR-stripped).
   - No `ports` field exists — add one from `configuration.publishedPorts[]`
     (needed for Containers-screen port display / open-in-browser).
   - No `labels` field exists — add one from `configuration.labels`
     (**required** for compose grouping, §4.3/§4.5).
   - `imageReference` mapping is already correct, no change.
   - Once these are fixed, move from tolerant (`try?`) to fail-loud decoding
     for required structural keys — the shape is now pinned by two
     independent real captures (this spike + S1's `inspect` cross-check),
     so silent tolerance is no longer earning its keep per finding #3's
     original caveat.

4. **Casing/shape drift from seeded assumptions:** none found beyond what's
   listed above. Finding #2 (lowerCamelCase, nested `configuration`) holds
   exactly as seeded, now confirmed against a populated `list` in addition to
   `image list`. The one **correction** to a prior finding is #5:
   `system status` DOES support `--format json` (previously recorded as
   "no `--format` flag tested yet") — the learnings note has been updated
   in place to reflect this, per the standing rule ("when a finding is
   invalidated, edit the note and say so").

## Deviations from the method sketch in `docs/plans/phases/P0-spikes.md`

None — the method sketch's commands all ran as written; the only additions
were `--no-stream` (discovered via `stats --help`, needed to capture one
JSON sample without an indefinite stream) and the explicit `--help`/error-text
captures for each `inspect` subcommand (to positively confirm "no `--format`
flag" rather than infer it from a single failed attempt).
