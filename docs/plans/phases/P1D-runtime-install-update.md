# P1D — Runtime install & update flow

Capsule manages its runtime dependency: detect a missing/outdated
`container` install, fetch the release from apple/container GitHub, guide the
user through install/update. Never silently install (AGENTS rule 7).

| | |
|---|---|
| Branch | `phase/p1d-runtime-install-update` |
| Depends on | nothing (fully parallel from day one) |
| Blocks | nothing |
| Owns | `Sources/ContainerClient/RuntimeUpdateChecker.swift` (only this file inside ContainerClient), new `Sources/RuntimeInstaller/` + tests, `App/Capsule/Onboarding/`, the `capsule runtime` CLI subcommand file it adds under `Sources/CapsuleCLI/` (coordinate the one-line subcommand registration in `CapsuleCommand.swift` with P2B — append-only) |

**Read first:** `AGENTS.md` (rules 1, 7); master plan §3 exit criteria ("app
survives CLI absence gracefully — onboarding screen with install/start
guidance"); `RuntimeUpdateChecker.swift` as it stands (latest-release fetch +
semver compare already work; doctor already consumes them).

## Deliverables

1. **`Sources/RuntimeInstaller/` module:**
   - `RuntimeReleaseFetcher` (move/wrap `RuntimeUpdateChecker`): latest +
     recent releases, resolve the `.pkg` asset and any published checksums.
     Verify live against the real GitHub API once and record the actual tag
     format + asset naming in a learnings note (currently assumed, flagged in
     the runtime-cli-observations note).
   - `RuntimeInstallGuide`: downloads the `.pkg` to `~/Downloads` (URLSession
     download task with progress reporting), verifies checksum when available,
     then **hands off** — reveal in Finder / `open` the installer. No
     privileged execution, ever.
   - `InstallState` model: `.missing`, `.unsupportedVersion`, `.updateAvailable
     (installed, latest)`, `.current` — computed from `ContainerBinaryLocator`
     + `cliVersion()` + fetcher; drives both UI and CLI.
2. **App onboarding (`App/Capsule/Onboarding/`):** first-run / runtime-missing
   screen replacing the raw error states: explains what `container` is, a
   download-with-progress button, install handoff, re-check on activation.
   Update-available banner component for P1B's System screen to adopt later.
3. **CLI:** `capsule runtime status|download` subcommand (status = the
   InstallState, machine-readable with `--json`); extend `doctor` to reuse
   InstallState instead of its inline logic.
4. Tests: fetcher against fixture JSON of the GitHub API response; InstallState
   matrix; no network in unit tests (protocolize the HTTP layer).

## Verification

`swift build && swift test`; `swift run capsule runtime status` against the
real machine (should say current or update-available truthfully);
`CAPSULE_CONTAINER_BIN=/nonexistent swift run capsule runtime status` → clean
`.missing` guidance; app onboarding renders in both states (fake the state in
previews).

## Out of scope

Capsule's own updates (Sparkle/Homebrew — P4) · runtime start/stop controls
(P1B System screen) · touching any other file in `Sources/ContainerClient/`.
