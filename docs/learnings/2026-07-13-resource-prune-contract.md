# Volume/network prune has no structured output

**Context:** Extending `ContainerRuntime` for the Phase 2 volume and network
frontends against `container` 1.1.0.

**Finding:** Neither resource prune command advertises `--format` or any other
structured-output option:

```sh
container volume prune --help
# USAGE: container volume prune [--debug]

container network prune --help
# USAGE: container network prune [--debug]
```

Both commands define only `--debug`, `--version`, and `--help`. This is a real
exception to the S2 list/inspect coverage: those read surfaces have JSON, but
prune itself does not return a stable machine-readable deletion report.

**Consequence:** `CLIProcessClient` snapshots the corresponding JSON list before
and after a successful prune and returns the exact set difference as
`PruneReport.removedNames`. Non-empty stdout/stderr lines are retained as
human-readable `notices`; Capsule does not parse deletion identity from prose.
If the runtime later adds structured prune output, replace this extra pair of
list calls with direct decoding and re-verify against that runtime version.
