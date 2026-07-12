# Spikes

Time-boxed experiments that de-risk architecture decisions (plan §5 M0 / §8).
One file per spike: `S<n>-<topic>.md` with **Question**, **Method (exact
commands)**, **Result**, **Decision**. A spike is done when its decision is
recorded here and reflected in docs/ROADMAP.md — durable *facts* discovered
along the way also get a note in docs/learnings/.

| Spike | Question | Status |
|---|---|---|
| S1 DNS/networks | Do bare service names (`db:5432`) resolve container-to-container on a user-defined network on macOS 26? Decides plan §4.4 (search-domains vs hosts-injection vs DNS proxy). | **decided 2026-07-13 — bare-name DNS fails (both networks, with and without `--dns-search`/`--dns-domain`); hosts injection verified non-sudo, ships as default. Search-domain primary path is sudo-gated, pending human verification. See [spike](S1-dns-service-discovery.md).** |
| S2 JSON coverage | Which commands emit `--format json`, and what are the exact shapes? | **decided 2026-07-13 — fully verified with a populated runtime; no table-only commands found; `ContainerSummary` tightening list handed off to P1A. See [spike](S2-json-coverage.md) and [learnings](../learnings/2026-07-12-runtime-cli-observations.md).** |
| S3 PTY/exec | Is SwiftTerm + `container exec -it` interactive quality acceptable (resize, colors, ctrl-c)? | open |
| S4 stats | `container stats` format and per-second cost of polling 10 containers? | open |
| S5 build cancel | SIGINT/SIGTERM semantics of `container build`; does cancellation leave builder state consistent? | open |
