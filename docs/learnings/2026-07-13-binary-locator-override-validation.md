# `ContainerBinaryLocator`'s override env var wasn't validated (found via P1D's missing-runtime smoke test)

**Context:** P1D's brief requires `CAPSULE_CONTAINER_BIN=/nonexistent capsule
runtime status` (and `doctor`/`ls`) to print clean missing-runtime guidance,
never a stack trace or raw subprocess error.

**Finding:** `ContainerBinaryLocator.locate()` validated its two fallback
candidates (`defaultInstallPath`, each `$PATH` entry) with
`FileManager.default.isExecutableFile(atPath:)` before returning them, but
returned the `$CAPSULE_CONTAINER_BIN` override **unconditionally**, without
the same check. So `CAPSULE_CONTAINER_BIN=/nonexistent` — meant to simulate a
missing runtime for exactly this kind of test — didn't produce
`RuntimeError.binaryNotFound` at all. Instead every consumer (`doctor`, `ls`,
the new `runtime status`, `RuntimeSession`) believed the binary was "found"
at `/nonexistent`, called it anyway, and surfaced whatever raw error the
first subprocess spawn/`Subprocess.run` attempt happened to produce:

- `capsule doctor`: `"✓ container CLI at /nonexistent"` followed by a garbled
  `SubprocessError` description — actively misleading (claims success, then
  fails).
- `capsule ls`: `Error: executableNotFound("/nonexistent")` — ArgumentParser
  printing a raw internal error case name, no guidance at all.
- `capsule runtime status` (new in P1D): same pattern as `doctor`.

**Fix:** `locate()` now validates the override with the same
`isExecutableFile` check as the other two candidates; an invalid override
returns `nil` directly (does **not** fall through to the real default
path/`$PATH` search — the override's purpose is to let a caller pin, or for
tests deliberately simulate the absence of, a specific binary regardless of
what's actually installed on the host). After the fix, all three commands
print the existing clean `RuntimeError.binaryNotFound` guidance:

```
✗ container CLI not found
  Searched: $CAPSULE_CONTAINER_BIN, /usr/local/bin/container, $PATH
  Install the signed package from https://github.com/apple/container/releases
```

**Consequence:** `ContainerBinaryLocator.locate()`'s override branch is now
symmetric with its other two branches. This was a genuine pre-existing bug
(not a documented design decision — no test covered it), fixed as a one-line
change in `Sources/ContainerClient/ContainerRuntime.swift` while implementing
P1D, even though that file is nominally outside P1D's owned-file boundary;
recorded here (and flagged in the P1D implementation report) as a
coordinated single-tree touch, same precedent as the earlier `DoctorCommand`
ripple.
