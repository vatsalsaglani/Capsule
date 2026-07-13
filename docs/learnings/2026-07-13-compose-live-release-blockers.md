# Compose live release blockers on container 1.1.0

**Context:** P2/P3 release-gate run of `Fixtures/compose/basic-web-db.yaml`
on macOS 26, Apple `container` 1.1.0, 2026-07-13.

## Reproduction

```sh
swift run capsule compose up -f Fixtures/compose/basic-web-db.yaml
container volume ls --format json
container network ls --format json
container list --all --format json
```

The generated plan originally placed custom-network creation, volume
creation, and both image pulls in the same parallel layer. The operation
stalled for more than 90 seconds after the volume appeared; the custom
network and containers never appeared. This is consistent with the earlier
S1 observation that `container-network-vmnet` can wedge under resource and
container churn, although the runtime does not expose enough diagnostics to
claim a root cause.

## Decisions

1. Compose plans now have a hard infrastructure barrier: managed networks
   and volumes complete before parallel image pulls/builds begin. Pulls and
   builds remain parallel, and service starts retain dependency-DAG order.
2. `ensureImage` first checks `image list` and skips a pull when the exact
   reference already exists, matching default Compose behavior and reducing
   unnecessary runtime churn.
3. Runtime 1.1 serializes an empty `--label capsule.service=` unexpectedly as
   a malformed-looking key/value (`"capsule.service=":""`). Project
   resources therefore keep all four Capsule labels but use deterministic,
   nonempty identities such as `network:<runtime-name>` and
   `volume:<runtime-name>` for `capsule.service`.
4. Health-gate hosts injection only inspects peers guaranteed started at that
   point (the health service's transitive dependencies). A final all-service
   refresh still runs after starts and remains the reconciliation repair path.

## Regression coverage

- Golden layered-plan output locks the infrastructure barrier and parallel
  pull layer.
- Executor tests lock exact-reference image skipping.
- Planner tests lock nonempty resource labels and pre-health peer scoping.

