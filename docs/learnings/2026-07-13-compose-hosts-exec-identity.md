# Compose hosts refresh needs an explicit container-local identity

**Context:** A Compose project containing Adminer reached Capsule's managed
`/etc/hosts` refresh with a non-root service/image user. A plain
`container exec` inherits that configured identity, so replacing
`/etc/hosts` failed even though the same reconciliation works in root-based
images. This was reported from the live project; the project was no longer
present locally when the fix was verified.

## Runtime contract

Apple `container` 1.1.0 documents an exec identity override:

```sh
container exec --help
```

Relevant output:

```text
USAGE: container exec [<options>] <container-id> <arguments> ...
-u, --user <user>       Set the user for the process (format: name|uid[:gid])
```

The tested argv mapping is therefore:

```text
exec
--user
0
adminer-1
sh
-c
<managed hosts script>
```

Options precede the container ID, and there is no `--` separator before the
process argv. Without `--user`, exec retains the container's configured
identity. A nonzero command exit remains an `ExecResult`; it is not converted
into a subprocess-launch error.

## API decision

`ExecOptions` is a small `Sendable`, `Hashable`, `Codable` value rather than a
raw flags escape hatch. The existing `ContainerRuntime.exec` requirement
remains source-compatible. A new options-bearing requirement has a default
witness that delegates for the default identity and fails loudly with
`RuntimeError.notImplemented` when an older conformer receives a user
override. This keeps the protocol ready for the future XPC transport without
silently discarding privileged intent.

Only Capsule's fixed managed-hosts reconciliation requests
`ExecOptions.containerRoot` (`user: "0"`). User-invoked Compose exec,
healthchecks, shell detection, and interactive PTY sessions continue to
inherit the service/image identity.

Container UID 0 is not host root and does not invoke `sudo` or `su`. It can
still write files made visible through container mounts, so the override is
deliberately confined to Capsule's fixed `/etc/hosts` script and is not
exposed as an unstructured general-purpose flag.

Elevating the maintenance command also changes the temporary-file threat
model. A predictable `tmp="/tmp/capsule-hosts.$$"` opened with ordinary
shell redirection lets the non-root service user pre-create a symlink that the
later UID-0 exec could follow. The POSIX/BusyBox-compatible script now uses a
restrictive umask and a bounded candidate loop with shell noclobber
(`set -C`) to atomically reject existing paths, installs a cleanup trap as
soon as a candidate is secured, and fails loudly if all candidates collide.
It still copies into `/etc/hosts` in place instead of renaming over it because
the runtime may expose that file as a managed mount.

## Verification

Scripted CLI tests lock the exact default and overridden argv, option
placement, and nonzero-result behavior. Runtime existential tests lock
gateway forwarding and the fail-loud default witness. Compose tests lock
root-only hosts refresh plus default-identity public exec, health probes, and
shell detection.

```sh
swift build && swift test
```

passed all 287 enabled tests; the three opt-in live-runtime tests remained
skipped. A regenerated Release `Capsule.app` and bundled `capsule` helper also
built successfully as universal arm64/x86_64 binaries and passed strict
ad-hoc signature verification.

At verification time:

```sh
container list --all --format json
```

listed only stopped `demo-nginx` and `demo-redis` containers. There was no
`local-dev`/Adminer project available for a non-destructive live regression
run, so the runtime-facing verification is the exact argv capture rather than
a recreated project.

**Finding:** Compose-owned maintenance cannot assume a service runs as root;
its identity must be explicit and narrowly scoped. Apple `container` 1.1.0
accepts numeric root as `container exec --user 0 <id> ...`.

**Consequence:** Capsule refreshes its managed `/etc/hosts` block as
container-local UID 0 while preserving the configured container identity for
all user commands and probes. Its root maintenance path also treats every
service-writable temporary directory as hostile and never follows a
pre-existing candidate.
