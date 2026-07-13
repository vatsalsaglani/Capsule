# Capsule CLI reference

`capsule` manages Apple `container` workloads, Compose-style projects,
volumes, networks, and the runtime dependency. It is a companion to
Capsule.app; both use the same CapsuleKit engine.

Capsule is pre-alpha and supports a deliberate Compose subset. It is not a
drop-in replacement for Docker Compose. Run `capsule compose config --report`
before `up` to see every ignored or fatal key in a file.

The examples below assume the built `capsule` executable is in `PATH`. From a
source checkout, replace `capsule` with `swift run capsule`.

## Global usage

```text
capsule <subcommand>
capsule --version
capsule help <subcommand>
capsule <subcommand> --help
```

The current development executable reports `0.1.0-dev`. Every command group
and leaf command also accepts `--version` and `-h, --help`.

| Command | Purpose |
|---|---|
| `capsule compose` | Manage a Compose-style project. |
| `capsule volumes` | Manage persistent volumes. |
| `capsule networks` | Manage container networks. |
| `capsule ls` | List containers across projects. |
| `capsule doctor` | Diagnose the Apple `container` installation. |
| `capsule runtime status` | Show runtime dependency and update status. |

Normal command output and Compose progress are written to standard output.
Argument, validation, and runtime failures exit non-zero with a diagnostic.
`capsule compose exec` passes the child command's standard output and standard
error through unchanged and returns its exact non-zero exit code.

## Compose conventions

Except where noted, Compose commands accept these shared options:

```text
-f, --file <file>                 Compose file
-p, --project-name <name>         Override the project name
--env-file <file>                 Interpolation environment file
```

Without `--file`, Capsule uses the first existing file in this order:

1. `compose.yaml`
2. `compose.yml`
3. `docker-compose.yaml`
4. `docker-compose.yml`

The project name is selected in this order: `--project-name`, the top-level
`name:` field, then the Compose file's parent-directory name. Relative build
contexts, bind mounts, service `env_file` paths, and the project `.env` file
are resolved from the Compose file's directory.

Interpolation precedence is the invoking process environment, then
`--env-file`, then the project-directory `.env`. A service's inline
`environment` values override its service-level `env_file` values.

Commands that accept `[services ...]` operate on all project services when no
service is named. For `up` and `plan`, named services include their declared
dependencies unless `--no-deps` is supplied.

### Progress output

`up`, `down`, `start`, `stop`, `restart`, `build`, and `pull` render progress.
On a capable TTY, Capsule uses in-place rows, progress bars, stable colors per
service, and event icons:

| Icon | Event |
|---|---|
| `◎` | Network creation or service-discovery refresh |
| `▰` | Volume creation |
| `⇣` | Image pull |
| `◆` | Image build |
| `▣` | Container creation or removal |
| `▶` | Container start |
| `■` | Container stop |
| `♥` | Health or completion wait |
| `✓` / `✗` | Step success / failure |

Output switches to bounded plain-text updates when standard output is not a
TTY, `TERM=dumb`, `CI` is enabled, `NO_COLOR` is nonempty, `CLICOLOR=0`, or the
number of active rows exceeds the terminal height. `--quiet` suppresses these
progress events; it does not suppress validation/support findings, errors, or
the `up --detach` supervision notice.

## `capsule compose config`

Resolve interpolation, validate the file, and print normalized YAML.

```text
capsule compose config [shared options] [--report]
```

`--report` also prints the service-discovery explanation and the complete
supported/unsupported-key report. Without it, findings are still printed when
there are any. Fatal findings make the command fail. This command is offline:
it does not require the Apple runtime to be installed or running.

```sh
capsule compose config -f compose.yaml --env-file .env.local --report
```

## `capsule compose plan`

Read current runtime state and print the execution plan without executing its
steps.

```text
capsule compose plan [shared options] [--build] [--force-recreate]
                     [--no-deps] [services ...]
```

- `--build` includes image builds for services that declare `build:`.
- `--force-recreate` plans container recreation even when configuration is
  unchanged.
- `--no-deps` does not add dependencies of explicitly selected services.

```sh
capsule compose plan --build web worker
```

## `capsule compose up`

Create required networks and volumes, build or pull images, create containers,
start services in dependency order, wait for declared dependency conditions,
and refresh Capsule-managed service discovery.

```text
capsule compose up [shared options] [--quiet] [-d|--detach] [--build]
                   [--force-recreate] [--no-deps] [services ...]
```

`--build`, `--force-recreate`, and `--no-deps` have the same meanings as for
`plan`. `--detach` returns after the operation and prints
`supervision requires the Capsule agent`; it does not start a CLI background
daemon.

```sh
capsule compose up --build
capsule compose up -d redis api
```

## `capsule compose down`

Stop and remove Capsule-owned project containers and networks.

```text
capsule compose down [shared options] [--quiet] [--volumes]
                     [--remove-orphans]
```

Named volumes are preserved by default. `--volumes` also removes the project's
Capsule-owned volumes. `--remove-orphans` also removes Capsule-labeled project
containers that are no longer present in the Compose file.

```sh
capsule compose down
capsule compose down --volumes --remove-orphans
```

## `capsule compose ps`

Print a project table with `SERVICE`, `INDEX`, `STATE`, and `CONTAINER`
columns. Capsule also prints a warning when stored and observed project state
have drifted.

```text
capsule compose ps [shared options]
```

## `capsule compose logs`

Read logs concurrently from selected project services.

```text
capsule compose logs [--file <file>] [-p|--project-name <name>]
                     [--env-file <file>] [-f|--follow] [-n|--tail <lines>]
                     [services ...]
```

For this command only, `-f` means `--follow`; use the long `--file` spelling
to choose a Compose file. Each line is prefixed as
`<service>-<index> | <message>`.

```sh
capsule compose logs --tail 100 api worker
capsule compose logs --file compose.prod.yaml -f
```

## Service lifecycle commands

```text
capsule compose start   [shared options] [--quiet] [services ...]
capsule compose stop    [shared options] [--quiet] [services ...]
capsule compose restart [shared options] [--quiet] [services ...]
```

- `start` starts existing project containers.
- `stop` stops existing project containers and applies a valid service
  `stop_grace_period` when configured.
- `restart` stops running project containers, then starts them.

These commands do not create missing containers. Omit service names to target
all existing containers belonging to the project.

## Image commands

```text
capsule compose build [shared options] [--quiet] [services ...]
capsule compose pull  [shared options] [--quiet] [services ...]
```

`build` builds selected services that declare `build:` without changing
container state. `pull` pulls images required by selected services without
creating project resources.

```sh
capsule compose build api
capsule compose pull
```

## `capsule compose exec`

Run a non-interactive command in an existing container for a service.

```text
capsule compose exec [shared options] <service> <command> ...
```

The command is passed as an argument vector, not as a shell string. There is
no interactive TTY mode or user override in this command. Execution has a
60-second timeout. Standard output and standard error are passed through, and
the executed command's non-zero exit code becomes Capsule's exit code.

```sh
capsule compose exec mysql mysqladmin ping -h 127.0.0.1
capsule compose exec redis redis-cli PING
```

## Supported Compose input

Capsule recognizes these top-level keys:

- `name`, `services`, `volumes`, and `networks`
- `version` is accepted but reported as obsolete and ignored

Recognized service keys are `image`, `build`, `command`, `entrypoint`,
`environment`, `env_file`, `working_dir`, `user`, `volumes`, `ports`,
`depends_on`, `healthcheck`, `restart`, `labels`, `networks`, `platform`,
`init`, `read_only`, `shm_size`, `tmpfs`, and `stop_grace_period`.

Nested supported keys are:

- `build`: `context`, `dockerfile`, `args`, `target`
- `healthcheck`: `test`, `interval`, `timeout`, `retries`, `start_period`,
  `disable`
- `depends_on.<service>`: `condition`, with `service_started`,
  `service_healthy`, or `service_completed_successfully`
- long-form `ports`: `target`, `published`, `protocol`, `host_ip`
- long-form service `volumes`: `type`, `source`, `target`, `read_only`
- top-level `volumes`: `external`, `name`
- top-level `networks`: `external`, `name`, `internal`

Short and long port syntax supports TCP and UDP. Port ranges and IPv6 host
literals are not supported. Service volumes support bind, named-volume, and
tmpfs mounts; named volumes must be declared at top level. Networks are
attach-only at the service level, so per-attachment options are reported as
unsupported.

Unknown keys are never silently dropped: warnings identify ignored keys, and
fatal findings block execution. `profiles`, `extends`, `secrets`, `configs`,
`deploy`, `develop`, `pull_policy`, `cpus`, and `mem_limit` are explicitly
reported as deferred and ignored.

### Current Compose limitations

- Automatic restart supervision is not active in the current frontend.
  `restart:` is recorded but produces a warning and is not enforced; this
  includes `always`, `unless-stopped`, and `on-failure` policies.
- `up --detach` does not install or start a resident supervisor.
- Health checks are used while satisfying declared `depends_on` conditions;
  continuous post-start health supervision is not resident yet.
- Apple `container` 1.1 does not publish container-name DNS records. Capsule
  injects and refreshes a managed `/etc/hosts` block for service discovery.
- `compose exec` is non-interactive and targets an existing service container.
- Compose features outside the subset above are ignored with warnings or
  rejected when continuing would be unsafe.

## Volumes

### List and inspect

```text
capsule volumes list
capsule volumes ls
capsule volumes inspect <name>
```

`list` prints `NAME`, `SIZE`, `OWNER`, and `USED BY`. `inspect` prints the
driver, format, size, ownership classification, and reverse container
references. Empty inventory prints `No volumes.`.

Ownership is shown as `capsule:<project>`, `capsule`, `external`, or `system`
according to the resource labels and runtime classification.

### Create

```text
capsule volumes create <name> [--capacity <bytes>] [--label <KEY=VALUE> ...]
```

`--capacity` is an unsigned byte count. `--label` is repeatable; when the same
key is repeated, the last value wins. Success prints the created volume name.

```sh
capsule volumes create app-data --capacity 10737418240 \
  --label environment=development --label owner=capsule
```

### Delete and prune

```text
capsule volumes delete <name> --force
capsule volumes rm <name> --force
capsule volumes prune --force
```

Both operations require `--force` because volume data deletion is permanent.
Deleting a volume still fails when the inventory reports container consumers.
`prune` deletes unused volumes, prints each removed name, then prints any
runtime notices. If nothing is removed, it prints
`No unused volumes removed.`.

## Networks

### List and inspect

```text
capsule networks list
capsule networks ls
capsule networks inspect <name>
```

`list` prints `NAME`, `MODE`, `SUBNET`, `OWNER`, and `CONTAINERS`. `inspect`
prints mode, IPv4 subnet and gateway, IPv6 subnet, ownership classification,
and attached containers. Empty inventory prints `No networks.`.

### Create

```text
capsule networks create <name> [--internal] [--subnet <ipv4-cidr>]
                        [--subnet-v6 <ipv6-cidr>] [--label <KEY=VALUE> ...]
```

The default connectivity is NAT. `--internal` creates a host-only network.
Labels are repeatable `KEY=VALUE` values, with the last repeated key winning.
Success prints the created network name.

```sh
capsule networks create app-net --subnet 192.168.100.0/24
capsule networks create isolated --internal --label environment=test
```

### Delete and prune

```text
capsule networks delete <name>
capsule networks rm <name>
capsule networks prune
```

`delete` prints the deleted network name. An attached or otherwise invalid
deletion is rejected by the runtime. `prune` deletes unused networks, prints
each removed name, then prints runtime notices. If nothing is removed, it
prints `No unused networks removed.`.

Unlike the volume equivalents, the currently implemented network commands do
not have a `--force` confirmation option.

## `capsule ls`

List containers across all projects.

```text
capsule ls [-a|--all]
```

By default only running containers are shown. `--all` includes containers that
are not running. The table columns are `ID`, `STATE`, `IMAGE`, and `ADDRESSES`.
An empty result prints `No running containers (try --all).` or, with `--all`,
`No containers.`. For a project-scoped view, use `capsule compose ps`.

## `capsule doctor`

Diagnose whether the Apple runtime dependency is usable.

```text
capsule doctor [--offline]
```

The command checks the `container` binary location, CLI version, runtime
apiserver state, and the latest GitHub release. `--offline` skips only the
GitHub check. A missing binary, unreadable version, or version older than 1.x
exits with status 1. A stopped or unqueryable apiserver is reported as a
warning with startup guidance. Update-check network failure is also a warning.

## `capsule runtime status`

Show dependency details without treating most status checks as a diagnosis
failure.

```text
capsule runtime status [--offline]
```

The output includes the resolved binary path, installed version, apiserver
running state, and update status. `--offline` prints that the update check was
skipped. A missing binary exits with status 1 and lists the searched locations:
`$CAPSULE_CONTAINER_BIN`, `/usr/local/bin/container`, and `$PATH`. Version,
status, and update-query failures are rendered as `unknown` or `could not`
lines instead of failing the command.
