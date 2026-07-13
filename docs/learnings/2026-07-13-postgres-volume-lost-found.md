# PostgreSQL needs a child data directory on Apple container volumes

**Context:** P2/P3 release-gate smoke testing of the PostgreSQL 16 service in
`Fixtures/compose/basic-web-db.yaml` on Apple `container` 1.1.0, 2026-07-13.

**Finding:** A named Apple container volume is an ext4 filesystem whose root
contains `lost+found`. When that root is mounted directly at PostgreSQL's
default data directory, PostgreSQL 16 refuses to initialize it. The exact
diagnostic was captured with:

```sh
container logs capsule-p2-smoke-db-1 2>&1
```

```text
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a lost+found directory, perhaps due to it being a mount point.
initdb: hint: Using a mount point directly as the data directory is not recommended.
```

Runtime inspection confirmed that the named ext4 volume was mounted directly
at `/var/lib/postgresql/data`. This is a volume-filesystem behavior, not a
Compose planner or executor failure.

**Consequence:** Keep the named volume mounted at
`/var/lib/postgresql/data`, but set
`PGDATA=/var/lib/postgresql/data/pgdata`. PostgreSQL creates and owns that
child directory, avoiding the ext4 root's `lost+found`. Fixtures and parser
coverage lock this requirement for live smoke tests.
