# Apple `container` CLI observations (v1.1.0)

**Context:** initial scaffold; grounding `ContainerClient` models in real
output instead of guesses. Machine: macOS 26 (Darwin 25.1.0), Apple silicon.

## Findings

1. **Installed version is 1.1.0, not 1.0.x.** `container --version` →
   `container CLI version 1.1.0 (build: release, commit: 5973b9c)`.
   The master plan assumed pinning to 1.0.x; the version gate accepts 1.x and
   doctor prints "developed against 1.1.x". Re-check the plan's claim that XPC
   APIs are frozen when we adopt the Swift packages (was stated for 1.0.x).

2. **JSON output is lowerCamelCase with nested `configuration` objects** —
   upstream Swift `Codable` types serialized directly. Verified via
   `container image list --format json`: keys like `creationDate`,
   `mediaType`, `configuration.name`, `variants[].platform`.

3. **`container list --format json` returns `[]` when empty** (clean empty
   array, not an error). The full populated shape is still unverified —
   `ContainerSummary.init(from:)` decodes tolerantly (only `configuration.id`
   required) until spike S2 captures a real container's JSON. **Do not trust
   the current field mapping for ports/networks until S2.**

4. **`--format` accepts `json`, `table`, `yaml`, `toml`** (from
   `container list --help`). Default is `table`.

5. **`container system status` prints a FIELD/VALUE table** (no `--format`
   flag tested yet). Doctor currently greps for `running` — fragile, revisit
   in S2.

6. **Version line format** is stable enough to regex: `x.y.z` after
   "version". `SemanticVersion(firstIn:)` handles it; also used for GitHub
   release tags (`apple/container` tags are plain `x.y.z`, no `v` prefix —
   verify when `RuntimeUpdateChecker` first runs against the live API).

## Consequences

- `CLIProcessClient` appends `--format json` and decodes with plain
  `JSONDecoder` (no key strategy needed — keys are already lowerCamelCase).
- Models stay tolerant (optionals + `try?`) until S2 pins the schema; after
  S2, tighten to fail loudly on shape drift.
- Doctor/gate logic: accept `major == 1`, warn otherwise.
