# Apple `container` CLI observations (v1.1.0)

**Context:** initial scaffold; grounding `ContainerClient` models in real
output instead of guesses. Machine: macOS 26 (Darwin 25.1.0), Apple silicon.

## Findings

1. **Installed version is 1.1.0, not 1.0.x.** `container --version` →
   `container CLI version 1.1.0 (build: release, commit: 5973b9c)`.
   The master plan assumed pinning to 1.0.x; the version gate accepts 1.x and
   doctor prints "developed against 1.1.x". Re-check the plan's claim that XPC
   APIs are frozen when we adopt the Swift packages (was stated for 1.0.x).

2. **JSON output is lowerCamelCase with nested `configuration` objects** —
   upstream Swift `Codable` types serialized directly. Verified via
   `container image list --format json`: keys like `creationDate`,
   `mediaType`, `configuration.name`, `variants[].platform`.

3. **`container list --format json` returns `[]` when empty** (clean empty
   array, not an error). **Populated shape now verified (spike S2,
   2026-07-13)** against two real containers (one with `-p 8099:80`, one
   with `--label capsule.project=demo --label capsule.service=web`) —
   captured verbatim below. `ContainerSummary.init(from:)`'s current
   top-level `networks` `CodingKey` **does not exist in real output** —
   confirmed dead code, always falling back to `[]`. See the tightening list
   at the bottom of this note; the "do not trust ports/networks" warning is
   now resolved into concrete fixes, not just a caveat.

   Full populated shape (`container list --all --format json`, pretty-printed,
   two containers — one plain, one labeled):

   ```json
   [
     {
       "configuration": {
         "capAdd": [], "capDrop": [],
         "creationDate": "2026-07-12T20:25:15Z",
         "dns": { "nameservers": [], "options": [], "searchDomains": [] },
         "id": "s2-probe",
         "image": {
           "descriptor": { "digest": "sha256:ec4ed8...", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 10229 },
           "reference": "docker.io/library/nginx:latest"
         },
         "initProcess": { "arguments": ["nginx", "-g", "daemon off;"], "...": "..." },
         "labels": {},
         "mounts": [],
         "networks": [
           { "network": "default", "options": { "hostname": "s2-probe", "mtu": 1280 } }
         ],
         "platform": { "architecture": "arm64", "os": "linux" },
         "publishedPorts": [
           { "containerPort": 80, "count": 1, "hostAddress": "0.0.0.0", "hostPort": 8099, "proto": "tcp" }
         ],
         "publishedSockets": [],
         "readOnly": false,
         "resources": { "cpuOverhead": 1, "cpus": 4, "memoryInBytes": 1073741824 },
         "rosetta": false,
         "runtimeHandler": "container-runtime-linux",
         "ssh": false,
         "stopSignal": "SIGQUIT",
         "sysctls": {},
         "useInit": false,
         "virtualization": false
       },
       "id": "s2-probe",
       "status": {
         "networks": [
           {
             "hostname": "s2-probe",
             "ipv4Address": "192.168.64.6/24",
             "ipv4Gateway": "192.168.64.1",
             "ipv6Address": "fd2e:2a8d:ce3a:268b:f03b:a4ff:fe79:435e/64",
             "macAddress": "f2:3b:a4:79:43:5e",
             "mtu": 1280,
             "network": "default",
             "variant": "reserved"
           }
         ],
         "startedDate": "2026-07-12T20:25:17Z",
         "state": "running"
       }
     },
     {
       "configuration": {
         "...": "... (identical shape) ...",
         "id": "s2-labeled",
         "labels": { "capsule.project": "demo", "capsule.service": "web" },
         "publishedPorts": []
       },
       "id": "s2-labeled",
       "status": { "...": "...", "state": "running" }
     }
   ]
   ```

   Key shape facts:
   - **Ports live at `configuration.publishedPorts[]`** (not `status`):
     `{containerPort, count, hostAddress, hostPort, proto}` — plural,
     per-mapping array.
   - **Labels live at `configuration.labels`** (flat `[String: String]`) and
     round-trip correctly through `list --format json` — confirmed with
     `capsule.project`/`capsule.service` test labels.
   - **Resolved network info lives at `status.networks[]`**, not
     `configuration.networks[]`. `configuration.networks[]` is the
     *requested* attachment (`{network, options: {hostname, mtu}}` — no
     address). `status.networks[]` is the *resolved* attachment:
     `{hostname, ipv4Address (CIDR, e.g. "192.168.64.6/24"), ipv4Gateway,
     ipv6Address (CIDR), macAddress, mtu, network, variant}`. **There is no
     top-level `networks` key** — it only exists nested under
     `configuration` and `status`. (Cross-checked against the S1
     `container inspect` capture — identical shape; `inspect` and `list`
     share this exact configuration/status structure.)
   - **State lives at `status.state`** (`"running"`/`"stopped"`, matches the
     `list` table's `STATE` column), not at a top-level `status` string —
     the current model's `.status` `CodingKey` decodes the wrong node
     (`status` is an *object*, not the state string).

4. **`--format` accepts `json`, `table`, `yaml`, `toml`** (from
   `container list --help`). Default is `table`.

5. **`container system status` DOES support `--format json`** — **correcting
   the earlier assumption** ("no `--format` flag tested yet"). Verified
   (spike S2): `container system status --format json` →

   ```json
   {"apiServerAppName":"container-apiserver","apiServerBuild":"release","apiServerCommit":"5973b9cc626a3e7a499bb316a958237ebe14e2ed","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","appRoot":"/Users/.../Library/Application Support/com.apple.container/","installRoot":"/usr/local/","status":"running"}
   ```

   Doctor's fragile `grep`-for-`running`-in-table-output should switch to
   `--format json` and decode `.status == "running"` — table-parsing is no
   longer necessary here.

6. **Version line format** is stable enough to regex: `x.y.z` after
   "version". `SemanticVersion(firstIn:)` handles it; also used for GitHub
   release tags (`apple/container` tags are plain `x.y.z`, no `v` prefix —
   verify when `RuntimeUpdateChecker` first runs against the live API).

7. **`inspect` subcommands (`container inspect`, `volume inspect`, `network
   inspect`, `image inspect`) have no `--format` flag at all** — confirmed
   via each command's `--help` (`Unknown option '--format'` when passed).
   This is not a table-only gap: **these commands always emit pretty-printed
   JSON by default**, unconditionally (2-space indent, spaces around `:` —
   cosmetically different from `list`'s compact JSON but identical schema).
   `CLIProcessClient` must NOT append `--format json` to any `inspect`
   invocation — doing so causes a hard CLI usage error (exit 64), not a
   silent fallback to table output.

8. **`volume ls`, `network ls`, `image list` all support `--format json`**
   and share the same lowerCamelCase/`configuration`-nested shape as
   `container list`:
   - `volume ls --format json`: `[{"configuration":{"creationDate","driver":"local","format":"ext4","labels":{},"name","options":{},"sizeInBytes","source"},"id"}]`
   - `network ls --format json`: `[{"configuration":{"creationDate","labels":{"com.apple.container.resource.role":"builtin" — the built-in `default` network's own label, distinct from any `capsule.*` labels the compose engine would set on project networks},"mode":"nat","name","options":{},"plugin":"container-network-vmnet"},"id","status":{"ipv4Gateway","ipv4Subnet","ipv6Subnet"}}]`
   - `image list --format json`: full OCI image-config-spec nested under
     `variants[].config` (history, rootfs diff_ids, per-platform digests) —
     confirms finding #2's seeded shape, now with a populated multi-image
     sample (`alpine`+`nginx`) rather than a guess.

9. **`container stats` supports `--format json` and a `--no-stream` flag**
   (the latter avoids needing to interrupt a streaming process to capture
   one sample — useful for any future one-shot poll). Verified:
   `container stats --no-stream --format json s2-probe` →
   ```json
   [{"blockReadBytes":21536768,"blockWriteBytes":8192,"cpuUsageUsec":19568,"id":"s2-probe","memoryLimitBytes":1073741824,"memoryUsageBytes":27713536,"networkRxBytes":21834,"networkTxBytes":602,"numProcesses":6}]
   ```
   Flat object, byte/usec units (not the table's human-formatted
   `"26.43 MiB"` strings) — decode directly, no unit-string parsing needed.
   Without `--no-stream`, `stats` streams indefinitely (one JSON array per
   tick) — full streaming-cost characterization is S4's job; this is only
   the light-touch shape confirmation the S2 brief asked for.

10. **`container system df` supports `--format json`** — exists and works,
    resolving the earlier "does it exist?" open question:
    ```json
    {"containers":{"active":1,"reclaimable":0,"sizeInBytes":455069696,"total":1},"images":{"active":1,"reclaimable":323076096,"sizeInBytes":650096640,"total":3},"volumes":{"active":0,"reclaimable":69390336,"sizeInBytes":69390336,"total":1}}
    ```
    Flat per-resource-type objects with `active`/`reclaimable`/`sizeInBytes`/
    `total` — no units parsing needed, unlike the table's human-formatted
    `"650.1 MB"` strings.

## Table-only commands (no working `--format json`)

After S2's survey, the **only** JSON-incapable surface found is the
`inspect` family (finding #7) — and that's not a limitation, since they
always emit JSON unconditionally. **No command tested lacks JSON entirely**;
`system status`/`system df`/`stats` (previously open questions) all support
it. P1A does not need a table-parser fallback for anything probed in S1/S2 —
revisit this line if a not-yet-tested command (e.g. `container builder
status`, owned by S5) turns out table-only.

## `ContainerSummary` tightening list (P1A hand-off)

Concrete fixes required in `Sources/ContainerClient/Models.swift`
(read for this spike, **not edited** — P1A's job):

1. **`status` is decoded as the wrong type.** Current code does
   `try? container.decode(String.self, forKey: .status)` — but `status` is
   an object (`{networks, startedDate, state}`), not a string. This always
   throws internally and silently falls back to `"unknown"`. Fix: decode a
   nested `Status` struct and read `.state` (`"running"`/`"stopped"`) as the
   summary's status string.
2. **Top-level `networks` `CodingKey` does not exist.** Real output has no
   `networks` key at the top level — only `configuration.networks` (request)
   and `status.networks` (resolved). Current code's
   `container.decode([NetworkAttachment].self, forKey: .networks)` always
   throws and falls back to `[]`, so `addresses` is silently always empty
   today. Fix: decode `status.networks[].ipv4Address` (strip the `/24` CIDR
   suffix — see the S1 addendum's CIDR-strip note) as the summary's
   `addresses`.
3. **No `ports` field exists on `ContainerSummary` at all.** Add one,
   decoded from `configuration.publishedPorts[]`
   (`{containerPort, count, hostAddress, hostPort, proto}`) — required for
   the Containers screen's port-mapping display and any "open in browser"
   affordance (ROADMAP Phase 1 item).
4. **No `labels` field exists on `ContainerSummary` at all.** Add one,
   decoded from `configuration.labels` (`[String: String]`, confirmed
   flat, no nesting) — **required for compose grouping** (§4.3/§4.5: the
   compose engine identifies "which containers belong to project X" via
   `capsule.project`/`capsule.service`/`capsule.index`/`capsule.config-hash`
   labels; without this field on the summary, ComposeRuntime cannot
   reconcile observed-vs-desired state from a `list` call alone and would
   need an extra `inspect` per container).
5. **`imageReference` mapping (`configuration.image.reference`) is
   correct as-is** — no change needed, confirmed against both the plain and
   labeled test containers.
6. **After these fixes, decoding should fail loudly, not tolerantly** — per
   finding #3's resolved status, the shape is now pinned by two real
   captures (this note + the S1 `inspect` cross-check), so `ContainerSummary`
   should move from `try?`-tolerant decoding to a `Decodable init(from:)`
   that throws on missing required keys, surfacing shape drift instead of
   silently defaulting. Optional-and-genuinely-optional fields (e.g. ports/
   labels can legitimately be absent-vs-empty) stay optional; required
   structural keys (`id`, `status.state`) should not swallow decode errors.

## Consequences

- `CLIProcessClient` appends `--format json` to `list`/`stats`/`system df`/
  `system status`/`volume ls`/`network ls`/`image list` and decodes with
  plain `JSONDecoder` (no key strategy needed — keys are already
  lowerCamelCase). **Never** append `--format` to any `inspect` subcommand —
  it errors (exit 64); those already emit JSON by default.
- **S2 is now fully verified with a populated runtime (2026-07-13)** — see
  the `ContainerSummary` tightening list above for the concrete fixes P1A
  applies; models can move from tolerant (`optionals`/`try?`) decoding to
  fail-loud decoding for the structural keys now that the shape is pinned by
  two independent real captures (this note + S1's `inspect` cross-check).
- Doctor/gate logic: accept `major == 1`, warn otherwise; doctor's apiserver
  check should switch from table-grepping to `system status --format json`
  (finding #5).
