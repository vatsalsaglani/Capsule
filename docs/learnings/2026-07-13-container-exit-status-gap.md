# Container inspect does not expose process exit status

**Context:** P3 restart supervision needs to distinguish a clean exit from a
failure for `restart: on-failure`. The existing `ContainerSummary` and
`ContainerDetail` models expose only `status.state`, so a live probe checked
whether the undecoded inspect payload carried an exit status.

**Finding (Apple `container` 1.1.0):** a container whose init process exits
with status 7 is reported only as `status.state = "stopped"`. Neither
`container inspect` nor `container list --all --format json` includes an exit
code, signal, or termination reason.

Exact probe (2026-07-13):

```sh
container create --name capsule-exit-probe \
  docker.io/library/alpine:latest sh -c 'exit 7'
container start capsule-exit-probe
container inspect capsule-exit-probe
container delete --force capsule-exit-probe
```

Relevant inspect output:

```json
{
  "configuration": {
    "initProcess": { "executable": "sh", "arguments": ["-c", "exit 7"] }
  },
  "status": {
    "networks": [],
    "startedDate": "2026-07-13T06:17:39Z",
    "state": "stopped"
  }
}
```

The probe resource was deleted immediately after capture.

**Consequence:** the CLI-backed supervisor cannot implement exact
`on-failure` semantics by polling runtime JSON alone. It can correctly apply
`always`/`unless-stopped` and suppress restarts for Capsule-recorded user
stops, but `on-failure` must remain explicitly limited until Capsule owns the
container process lifecycle/exit observation or the future XPC runtime exposes
termination status. Never invent a nonzero exit code from the generic
`running -> stopped` transition. Re-test when moving to Apple's Swift/XPC API
or when the CLI moves beyond 1.1.x.
