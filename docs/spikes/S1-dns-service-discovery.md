# S1 — DNS / service discovery

**Status:** decided (2026-07-13) — fallback path shipping, primary path pending human sudo verification.

## Question

On macOS 26 with `container` 1.1.0, can container B reach container A by bare
name (`http://a/`) on a user-defined network? If not, which of the §4.4
options (search domains → hosts injection → DNS proxy) is the cheapest that
works, non-sudo?

Decides master plan §4.4.

## Machine state (reconfirmed before starting)

```
$ container --version
container CLI version 1.1.0 (build: release, commit: 5973b9c)
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED
$ container network ls
NETWORK  SUBNET
default  192.168.64.0/24
$ container image ls
NAME    TAG     DIGEST
alpine  latest  28bd5fe8b56d
$ container system dns list
DOMAIN
(empty)
```

Clean slate confirmed: no containers, only `default` network, no DNS domains,
only `alpine:latest` pulled locally (matches the advisor's pre-probe).

## Method (exact commands, in order)

### 1. Setup — custom network `s1-net`, two containers

```sh
container network create s1-net
container run -d --name s1-web --network s1-net docker.io/library/alpine:latest \
  sh -c 'mkdir -p /www && echo s1-web-ok > /www/index.html && httpd -f -p 80 -h /www'
container run -d --name s1-probe --network s1-net docker.io/library/alpine:latest sleep 3600
```

**Deviation — busybox httpd unavailable:** `s1-web` immediately went to
`stopped`; `container logs s1-web` showed:

```
sh: httpd: not found
```

`container exec s1-probe which httpd` also returned nothing on the same
`alpine:latest` image (`docker.io/library/alpine:latest`, digest
`28bd5fe8b56d…`) — the busybox multi-call binary in this image build does not
link the `httpd` applet. Per the brief's documented contingency, `s1-web` was
deleted and recreated with `docker.io/library/nginx:latest` (one pull
accepted). This affected **both** the custom-network and default-network web
containers (`s1-web`, `s1-web2`) — recorded here once, not per-section.

`container inspect s1-web` (post-fallback, nginx) — IP + networks/labels shape
(free S2 pre-work):

```json
{
  "configuration": {
    "dns": { "nameservers": [], "options": [], "searchDomains": [] },
    "labels": {},
    "networks": [
      { "network": "s1-net", "options": { "hostname": "s1-web", "mtu": 1280 } }
    ]
  },
  "status": {
    "networks": [
      {
        "hostname": "s1-web",
        "ipv4Address": "192.168.65.4/24",
        "ipv4Gateway": "192.168.65.1",
        "ipv6Address": "fda4:7552:f72:a72e:...",
        "macAddress": "fa:2b:a8:52:5a:3a",
        "mtu": 1280,
        "network": "s1-net",
        "variant": "reserved"
      }
    ],
    "state": "running"
  }
}
```

Labels are empty by default (`container run` does not auto-label; the compose
engine must pass `--label capsule.project=...` etc. itself, per AGENTS rule 5
— confirms nothing free happens here).

### 2. Baseline observation

```
$ container exec s1-probe cat /etc/resolv.conf
nameserver 192.168.65.1

$ container exec s1-probe cat /etc/hosts
127.0.0.1 localhost
192.168.65.3 s1-probe

$ container exec s1-web hostname
s1-web
```

Notable: `/etc/resolv.conf` has **no `search`/`domain` line by default** and
`/etc/hosts` contains only the container's own entry — the runtime does not
self-populate peer entries on a user-defined network.

### 3. Resolution ladder on `s1-net` (record PASS/FAIL each rung)

```
$ container exec s1-probe nslookup s1-web
Server:  192.168.65.1
** server can't find s1-web: NXDOMAIN
→ FAIL

$ container exec s1-probe wget -qO- -T 3 http://s1-web/
wget: bad address 's1-web'
→ FAIL

$ container exec s1-probe wget -qO- -T 3 http://192.168.65.4/
<!DOCTYPE html>...Welcome to nginx!...
IP-WORKS
→ PASS (on a freshly created network — see the L3-stability caveat below)

# resolv.conf has no domain/search line, so no FQDN form is suggested to try;
# tried a plausible guess anyway:
$ container exec s1-probe nslookup s1-web.local
** server can't find s1-web.local: NXDOMAIN
→ FAIL

$ container exec s1-probe nslookup s1-web 192.168.65.1   # explicit nameserver from resolv.conf
** server can't find s1-web: NXDOMAIN
→ FAIL (in-VM resolver does not answer container names at all)
```

### 4. Default-network variant

Same fallback needed: `s1-web2` (alpine + busybox httpd) went `stopped` with
the identical `sh: httpd: not found`; recreated with `nginx:latest`.

```
$ container exec s1-probe2 cat /etc/resolv.conf
nameserver 192.168.64.1

$ container exec s1-probe2 nslookup s1-web2
** server can't find s1-web2: NXDOMAIN
→ FAIL

$ container exec s1-probe2 wget -qO- -T 3 http://s1-web2/
wget: bad address 's1-web2'
→ FAIL
```

Identical failure mode to the custom network — the default network gets no
special treatment either.

### 5. DNS-flag variants (`--dns-search`, `--dns-domain`)

```sh
container run -d --name s1-probe3 --network s1-net --dns-search s1proj.capsule docker.io/library/alpine:latest sleep 3600
```

```
$ container exec s1-probe3 cat /etc/resolv.conf
nameserver 192.168.65.1
search s1proj.capsule
```

The flag **does plumb through** to `resolv.conf` (adds the `search` line).
First-pass query attempts intermittently returned `connection timed out; no
servers could be reached` rather than `NXDOMAIN` (see the stability caveat
below); re-verified cleanly on a second, freshly created network
(`s1-net-b`/`s1-probe-c`, same `--dns-search test.capsule` flag):

```
$ container exec s1-probe-c cat /etc/resolv.conf
nameserver 192.168.65.1
search test.capsule

$ container exec s1-probe-c nslookup s1-web-b
** server can't find s1-web-b.test.capsule: NXDOMAIN
→ FAIL (search-domain expansion attempted, still NXDOMAIN)

$ container exec s1-probe-c wget -qO- -T 5 http://s1-web-b/
wget: bad address 's1-web-b'
→ FAIL

$ container exec s1-probe-c wget -qO- -T 5 http://192.168.65.4/
<!DOCTYPE html>...   → PASS (IP still fine on the same container)
```

`--dns-domain` behaves identically (tested as `s1-probe4 --network s1-net
--dns-domain s1proj.capsule`):

```
$ container exec s1-probe4 cat /etc/resolv.conf
nameserver 192.168.65.1
domain s1proj.capsule

$ container exec s1-probe4 nslookup s1-web
→ FAIL (same NXDOMAIN/timeout pattern)
```

**Conclusion for step 5:** both flags edit `resolv.conf` correctly, but the
in-VM DNS resolver never answers container names — neither bare nor
search/domain-qualified. There is no evidence the runtime's DNS forwarder does
anything with container names at all on 1.1.0; `--dns-search`/`--dns-domain`
only affect musl's client-side query expansion, which is futile against an
upstream that never had the records.

Also confirmed: **`container run`/`container create` on 1.1.0 have no
`--add-host`-style flag** (48 options total; only `-p`/`--publish` and
`--publish-socket` match a "host" grep) — see
[learnings finding #9](../learnings/2026-07-13-container-dns-discovery.md).
This is why hosts injection uses `container exec` append as its transport,
not a `run`-time flag.

### 6. Fallback A — hosts injection (non-sudo)

```
$ container exec s1-probe-b sh -c 'echo "192.168.65.4 s1-web-b" >> /etc/hosts'
$ container exec s1-probe-b cat /etc/hosts
127.0.0.1 localhost
192.168.65.3 s1-probe-b
192.168.65.4 s1-web-b

$ container exec s1-probe-b wget -qO- -T 3 http://s1-web-b/
<!DOCTYPE html>...Welcome to nginx!...
HOSTS-INJECTION-WORKS
→ PASS, unambiguous
```

Result was clean (musl-libc alpine reads `/etc/hosts` and resolves the bare
name correctly) — **no debian cross-check needed** per the brief's "only if
ambiguous" clause.

### 7. Requires human — not executed (sudo variant, documented only)

```sh
sudo container system dns create s1test        # then re-run steps 3/5 with --dns-domain s1test
sudo container system dns delete s1test        # cleanup
```

Confirmed without running: `container system dns create|delete` reply
`"must run as an administrator"` (the sudo wall) when attempted non-sudo (per
advisor's live probe, reconfirmed by the CLI's own help/error text observed
during this session — never invoked with `sudo`).

Also confirmed: **`container system property` has only `list` in 1.1.0 — no
`set` subcommand.** `container system property list` output (captured this
session):

```
[dns]
[network]
[registry]
domain = "docker.io"
...
```

There is no `dns.domain` (or similar) settable property — so there is no
property-based, non-sudo route to a default search domain either. The only
non-sudo primary-path lever is the per-`run` `--dns-search`/`--dns-domain`
flags, and step 5 shows those don't achieve resolution on their own without a
working DNS-serving side (which `system dns create` would provide, but that's
sudo-gated).

### 8. L3-stability caveat (unplanned but load-bearing finding)

Mid-session, after `s1-net` had accumulated four containers
(`s1-web`, `s1-probe`, `s1-probe3`, `s1-probe4`) and `s1-web` was stopped/
started once, container-to-container **IP** connectivity on that network
degraded from PASS to FAIL (`wget: can't connect to remote host: Host is
unreachable`, later `ping` 100% packet loss) for every pair tried, including
after deleting the extra containers and after a second stop/start of
`s1-web`. The `default` network (`s1-probe2` ↔ `s1-web2`) was unaffected the
whole time.

To isolate whether this was a fundamental custom-network limitation (which
would have forced the hard-stop branch — see brief §"IP-WORKS failing... this
changes §4.4 entirely") or a transient/reproducible-flake in the
`container-network-vmnet` plugin, a **fresh** network (`s1-net-b`) was created
and retested:

```
$ container network create s1-net-b
$ container run -d --name s1-web-b --network s1-net-b docker.io/library/nginx:latest
$ container run -d --name s1-probe-b --network s1-net-b docker.io/library/alpine:latest sleep 3600
$ container exec s1-probe-b wget -qO- -T 5 http://192.168.65.2/
<!DOCTYPE html>...   → PASS immediately on the fresh network
```

A single `stop`/`start` of `s1-web-b` (IP reassigned .4) still passed. Adding
a `--dns-search`-flagged container to the same network did not immediately
reproduce the wedge either. **Conclusion:** IP-based L3 connectivity on a
custom network fundamentally works (confirmed PASS on two independently
created networks) but the `container-network-vmnet` plugin exhibited a
one-time degraded/wedged state after multiple container churn events
(create/delete/restart cycles) that did not clear until the network was
deleted and recreated. This is a reliability caveat for the runtime, **not**
evidence against IP reachability as a capability — recorded in the learnings
note as a durable but not-fully-diagnosed fact; root cause (ARP/route cache
on the vmnet bridge, ancestor of the ipv4Address reassignment on restart) is
unconfirmed and out of scope for this spike to fully diagnose.

### Cleanup verification

```
$ container ls --all
ID  IMAGE  OS  ARCH  STATE  IP  CPUS  MEMORY  STARTED
(empty)
$ container network ls
NETWORK  SUBNET
default  192.168.64.0/24
$ container system dns list
DOMAIN
(empty)
```

Back to baseline. (Pulled `nginx:latest` image remains locally — out of scope
per the brief; only containers/volumes/networks are cleaned.)

## Resolution-ladder summary

| Rung | Custom network (`s1-net`) | Default network | Notes |
|---|---|---|---|
| Bare name (`nslookup`/`wget`) | FAIL (NXDOMAIN) | FAIL (NXDOMAIN) | consistent, both networks |
| IP address | **PASS** (fresh network) | PASS | fresh-network PASS is the load-bearing L3 sanity check; see stability caveat for one transient wedge |
| FQDN guess (`s1-web.local`) | FAIL (NXDOMAIN) | not applicable | resolv.conf has no domain/search by default, nothing to try |
| `--dns-search <domain>` | resolv.conf updated; lookup still FAIL | not tested (custom-net only per brief) | flag plumbs through; doesn't create records |
| `--dns-domain <domain>` | resolv.conf updated; lookup still FAIL | not tested | same as above |
| Hosts injection (Fallback A) | **PASS**, unambiguous | not tested (custom-net only per brief) | verified path |
| `sudo container system dns create` | documented only, never run | — | sudo wall confirmed |

## Escalation branch taken

**Proceed with documented fallback.** Bare name and search-domain paths fail
on both networks; hosts injection (Fallback A) passes cleanly and
unambiguously non-sudo. IP-based L3 reachability was confirmed to
fundamentally work (fresh-network PASS on two independent networks), so the
"no working non-sudo path at all" / "IP-WORKS failing" hard-stop conditions do
**not** apply — the mid-session IP degradation was isolated to a
non-fundamental runtime/plugin stability issue (documented as a caveat, not a
capability gap).

## Decision

1. **Discovery mechanism P2A implements:** Fallback A — **hosts injection**.
   Evidence: bare-name DNS fails identically on the custom network and the
   default network (`NXDOMAIN` in both cases, in-VM resolver never has
   records for container names); `--dns-search`/`--dns-domain` correctly edit
   `resolv.conf` but do not produce resolvable records (still `NXDOMAIN`
   after search-domain expansion); hosts injection passed cleanly and
   unambiguously (`HOSTS-INJECTION-WORKS`, no debian cross-check needed).
   The primary approach (DNS search domains via `system dns create`) is
   **sudo-gated** and therefore not viable as the default, zero-friction
   experience — it becomes an optional upgrade path pending human sudo
   verification (point 4).

2. **Per-container flags / network-create flags for compose `container
   run`:** **none required** for the hosts-injection path — no `--dns`,
   `--dns-search`, or `--dns-domain` flags are needed on `container run`.
   Network creation stays `container network create <project>_default
   --label capsule.project=<project>` (per master plan §4.3, unchanged).
   The compose engine (ComposeRuntime, Phase 2) instead:
   - resolves each service's container IP after `EnsureContainer`/`Start`
     (via `container inspect` — the `status.networks[].ipv4Address` shape
     captured above),
   - appends `<ip> <service-name>` lines to every *other* running project
     container's `/etc/hosts` via `container exec ... sh -c 'echo ... >>
     /etc/hosts'` (idempotency: check-before-append or a marker block,
     TBD in P2A's implementation task — flagging this as an open detail
     for P2A, not decided here),
   - re-injects on every IP change (container restart, recreate) — this is
     supervisor work per plan §4.4/§4.5 (`WaitStarted` → hosts-injection
     step), consistent with AGENTS rule 6 (supervisor stays serializable/
     agent-ready; this is just another reconciliation step it owns).

   **Three things P2A must know about this transport (added 2026-07-13,
   post sign-off addendum — none of these change the mechanism):**

   - **No `run`-time flag exists.** `container run`/`container create` on
     1.1.0 have no `--add-host` or any hosts-file flag (verified: 48 options,
     only `-p`/`--publish` and `--publish-socket` match a "host" grep — see
     [learnings finding #9](../learnings/2026-07-13-container-dns-discovery.md)).
     `container exec ... sh -c 'echo ... >> /etc/hosts'` is therefore the
     *only* non-sudo per-entry hosts-write path available — this is why
     injection is exec-based rather than a `run` flag.
   - **Shell-less / read-only targets break exec injection.** It requires the
     target container to have a shell and a writable `/etc/hosts`.
     Distroless/static images and any future `read_only: true` support break
     this transport. The spike only injected into `alpine` (musl-libc, has
     `sh`, writable filesystem) — this was never tested against a
     shell-less or read-only image. P2A's `SupportReport`/
     `compose config --report` must define **loud** per-container behavior
     when injection fails: warn, name the affected container, and state
     explicitly that peers will not resolve it by name (per AGENTS rules
     4/10 — no silent dropping).
   - **Boot-time race.** Injection can only happen after the target
     container is already running (needs its IP from `inspect`), so a
     dependent's PID 1 may attempt to resolve `db` before the exec lands —
     even with correct DAG ordering from `depends_on`. This is a real
     failure mode for apps that don't retry DNS/connect failures at startup.
     Mitigation: inject as the *immediate* post-`Start` step (minimize the
     window) and document the caveat in `compose config --report`/docs — not
     eliminated, just narrowed. Flagging as an **open P2A experiment** (not
     decided here): bind-mounting a Capsule-generated hosts file over
     `/etc/hosts` at `run` time, which would eliminate both the race *and*
     the shell-less limitation above, if virtiofs write-propagation
     cooperates (unverified — P2A's job to spike if the exec-race proves
     troublesome in practice). The shipping *mechanism* stays "hosts
     injection" either way; only the *transport* (exec-append vs.
     mount-time file) is open for refinement.
   - **CIDR-strip note.** `status.networks[].ipv4Address` is CIDR-form
     (e.g. `"192.168.65.4/24"`, per the `inspect` capture above) — the `/24`
     suffix **must** be stripped before writing to `/etc/hosts`; nobody
     should ship a literal `192.168.65.4/24 db` line.

3. **Naming tension (§4.3/AGENTS rule 5 vs §4.4 name=service assumption):**
   **Both are satisfied without contradiction.** AGENTS rule 5's deterministic
   name (`<project>-<service>-<n>`) stays the actual `container run --name`.
   The hosts-injection fallback does **not** require container name to equal
   service name — it injects `<ip> <service-name>` (and, for `-1`-indexed
   single-instance services, optionally `<ip> <service-name>-1` as an alias)
   regardless of what the container's real name is. This is actually a
   **point in favor of hosts injection over the search-domain primary path**:
   the search-domain approach (option 2 in §4.4) implicitly assumed container
   name = service name for `db.<proj>.capsule` to read naturally as "the `db`
   service," which conflicts with rule 5's `<project>-db-1` naming — hosts
   injection sidesteps that tension entirely because the `/etc/hosts` entry
   is just data, decoupled from the container's actual name. No amendment to
   rule 5 is needed.

4. **The sudo story:** yes, `sudo container system dns create capsule`
   (shared domain, created once at install per master plan §4.4 option 2) is
   the primary path's prerequisite, and it remains **sudo-gated and
   unverified by this spike** (documented, never executed, per the brief's
   hard constraint). Per AGENTS §3 (sudo ops are copy-command, never
   shelled): if a human later verifies the primary path works, it becomes a
   **P1D-onboarding** step — `capsule doctor` prints the exact copy-command
   (`sudo container system dns create capsule`) with an explanation, the user
   runs it manually, and `doctor` re-checks `container system dns list` for
   the `capsule` domain to confirm. Capsule itself never shells out to
   `sudo`. Until that human verification lands, hosts injection is the
   **shipping default** — no user action, no sudo, works today.

5. **What `capsule compose config --report` must print** (master plan §4.4
   last line) — exact sentence templates per mechanism outcome:
   - Default (hosts-injection, no `capsule` DNS domain present):
     `"Service discovery: hosts-file injection. '<service>' resolves to
     <n> other service(s) in this project via /etc/hosts entries maintained
     by Capsule; entries refresh on container restart or recreate."`
   - If/when the primary path is verified and the `capsule` domain exists
     (`container system dns list` shows it): `"Service discovery: DNS search
     domain (<project>.capsule). '<service>' resolves via
     <service>.<project>.capsule through the shared 'capsule' DNS domain
     (one-time sudo setup already completed on this machine)."`
   - If neither is available (domain absent and, hypothetically, hosts
     injection disabled by a future flag): `"Service discovery: none
     configured. Containers in this project can only reach each other by
     IP address — see 'capsule compose ps' for current IPs."` (not currently
     reachable in practice since hosts injection is always-on by default,
     but specified for completeness / future `--no-discovery` escape hatch).

6. **Sudo-gated primary status:** **UNVERIFIED, pending human.** The
   interim shipping answer is hosts injection (point 1), which is fully
   verified non-sudo in this session and requires no follow-up before P2A
   can build on it. The primary path's sudo commands are captured in §7
   above for whoever performs the human verification step; P2A should not
   block on it.

## Deviations from the method sketch in `docs/plans/phases/P0-spikes.md`

- Busybox `httpd` applet is not present in the pulled `alpine:latest` build;
  fell back to `nginx:latest` for both `s1-web` and `s1-web2`, exactly as the
  brief's contingency anticipated.
- Because the custom network's L3 connectivity degraded mid-session (§8
  above), re-created the network once (`s1-net-b` with `s1-web-b`/
  `s1-probe-b`/`s1-probe-c`) to distinguish a fundamental capability failure
  from a transient runtime/plugin issue before recording the Decision. This
  consumed one extra `nginx:latest` pull-equivalent (already cached, no
  re-pull) and left a residual naming asymmetry (`-b` suffixed resources)
  which is called out here and was fully cleaned up per the cleanup section.
