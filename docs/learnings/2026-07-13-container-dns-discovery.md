# Container DNS / service discovery (v1.1.0)

**Context:** spike S1 (`docs/spikes/S1-dns-service-discovery.md`), deciding
master plan §4.4 — can container B reach container A by bare name on a
user-defined network. Machine: macOS 26 (Darwin 25.1.0), `container` 1.1.0,
Apple silicon.

## Findings

1. **Bare-name resolution does not work, on either network type.**
   `container exec <probe> nslookup <name>` returns `NXDOMAIN` for a peer
   container's name, whether the two containers share a user-defined network
   (`container network create`) or both use the implicit `default` network.
   The in-VM resolver has no records for container names at all — not a
   networking/firewall issue, a pure absence of DNS records.

2. **`/etc/resolv.conf` has no `search`/`domain` line by default** — just
   `nameserver <gateway-ip>` (the network's `.1` address, e.g.
   `192.168.65.1` for a custom network, `192.168.64.1` for `default`).
   `/etc/hosts` only contains the container's own hostname entry — the
   runtime does not pre-populate peer entries on a user-defined network.

3. **`--dns-search <domain>` and `--dns-domain <domain>` (on `container
   run`) both plumb through correctly to `/etc/resolv.conf`** (`search
   <domain>` / `domain <domain>` line added respectively) but do **not**
   make bare names resolve. `nslookup <name>` on a `--dns-search`-flagged
   container attempts search-domain expansion (visible as
   `<name>.<domain>` in the NXDOMAIN error) and still fails — the DNS
   forwarder never had records to answer with regardless of query form.
   One run intermittently returned `connection timed out; no servers could
   be reached` instead of a clean `NXDOMAIN` for the same query — re-run on
   a fresh container/network gave a clean, reproducible `NXDOMAIN`; treat the
   timeout as transient flake in the resolver path, not a distinct failure
   mode.

4. **Hosts injection works, unambiguously, non-sudo.** Appending `<ip>
   <name>` to `/etc/hosts` via `container exec <c> sh -c 'echo "<ip> <name>"
   >> /etc/hosts'` makes `wget http://<name>/` succeed immediately on
   `alpine:latest` (musl-libc). Result was clean on first try — the
   "cross-check once with debian if ambiguous" contingency in the S1 method
   was not needed.

5. **`container system dns create|delete <domain>` requires sudo** — running
   it non-sudo replies `"must run as an administrator"`. This is the sudo
   wall for the primary (§4.4 option 2) discovery path; **not executed** in
   this session (documented only, per spike constraint). No non-sudo
   equivalent exists.

6. **`container system property` has only a `list` subcommand in 1.1.0 — no
   `set`.** Verified via `container system property list` (durable fact,
   distinct from finding #5): there is no property-based way to configure a
   default DNS domain/search-suffix without the sudo-gated `system dns
   create`. Full `list` output has sections `[build] [container] [dns]
   [kernel] [machine] [network] [registry] [vminit]` — `[dns]` and
   `[network]` are both empty by default; `[registry].domain = "docker.io"`
   is the only populated leaf under those top-level sections.

7. **`container inspect <name>` shape for network status** (free S2
   pre-work): `status.networks[]` is an array of objects with `hostname`,
   `ipv4Address` (CIDR form, e.g. `"192.168.65.4/24"`), `ipv4Gateway`,
   `ipv6Address`, `macAddress`, `mtu`, `network`, `variant`. This differs
   from `configuration.networks[]`, which only has `network` + `options`
   (the *requested* attachment, not the *resolved* IP) — the resolved IP is
   **only** available via `status`, not `configuration`. `configuration
   .labels` is `{}` unless the caller passes `--label` explicitly —
   `container run` does not auto-label anything.

8. **Custom-network IP (L3) connectivity is fundamentally sound but the
   `container-network-vmnet` plugin exhibited a one-time reliability wedge.**
   Container-to-container `wget`/`ping` by IP address passed cleanly
   immediately after creating a fresh custom network (confirmed twice, on
   two independently created networks). Mid-session, after one network had
   accumulated 4 containers and one `stop`/`start` cycle, IP connectivity
   between *every* pair on that network degraded to `Host is unreachable` /
   100% ping loss and did not recover even after deleting the extra
   containers or a second `stop`/`start` — only deleting and recreating the
   network cleared it. Root cause unconfirmed (suspect stale ARP/route state
   on the vmnet bridge surviving container IP reassignment across
   restarts) — **not** re-diagnosed further since it didn't change the
   discovery decision (a fresh network reliably passes the L3 sanity check),
   but flagging as a runtime reliability caveat worth re-testing if P1B/P3
   surfaces intermittent connectivity reports from users.

## Consequences

- P2A (compose engine) implements service discovery via **hosts injection**,
  not DNS search domains — no special `container run` flags needed for
  discovery. See the full Decision in
  `docs/spikes/S1-dns-service-discovery.md` for the exact mechanism,
  `compose config --report` sentence templates, and how this coexists with
  the deterministic `<project>-<service>-<n>` naming (AGENTS rule 5) —
  hosts-injection decouples the "name resolvable by peers" concern from the
  "actual container name" concern entirely, so rule 5 needs **no
  amendment**.
- The primary path (`sudo container system dns create capsule`) stays
  documented-but-unverified; if a human verifies it, it becomes a
  `capsule doctor` copy-command onboarding step (AGENTS §3: sudo ops are
  copy-command, never shelled) — never something Capsule calls directly.
- S2 (JSON coverage spike) can reuse finding #7 for `ContainerSummary`/
  inspect-model shape work — resolved network info lives in `status`, not
  `configuration`.
- Doctor/compose-runtime code should not assume network stability under
  heavy container churn on a single custom network; if flaky connectivity
  reports surface later, revisit finding #8's suspected root cause.
