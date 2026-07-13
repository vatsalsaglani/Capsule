# Runtime installer: apple/container GitHub release shape (P1D)

**Context:** P1D built `RuntimeInstaller`'s download/handoff flow
(`RuntimeInstallerModel.prepareInstaller()`) and needed to know exactly what
`api.github.com/repos/apple/container/releases/latest` returns — the phase
doc flagged the tag format and asset naming as "assumed, unverified."

**Finding:** live `curl` against the real API on 2026-07-13:

```
$ curl -s https://api.github.com/repos/apple/container/releases/latest
tag_name: 1.1.0
html_url: https://github.com/apple/container/releases/tag/1.1.0
assets:
  container-1.1.0-installer-signed.pkg -> .../download/1.1.0/container-1.1.0-installer-signed.pkg
  container-dSYM.zip                   -> .../download/1.1.0/container-dSYM.zip
  container-installer-unsigned.pkg     -> .../download/1.1.0/container-installer-unsigned.pkg
```

- Tags are plain `x.y.z`, no `v` prefix (already noted in
  `2026-07-12-runtime-cli-observations.md`; this confirms it against the
  *release* tag specifically, not just `container --version` output).
- **The release ships two `.pkg` assets at once**: a signed
  `container-<version>-installer-signed.pkg` and an unsigned
  `container-installer-unsigned.pkg`. `GitHubRelease.installerPackage`
  originally picked `assets.first { $0.name.hasSuffix(".pkg") }` — whichever
  came first in API response order, with no guarantee that's the signed one.
  Fixed to explicitly prefer a name that doesn't contain `"unsigned"`,
  falling back to any `.pkg` only if nothing else matches.
- A `container-dSYM.zip` asset is also present and must be excluded by the
  `.pkg` suffix filter (it already was — just noting it's real, not a
  hypothetical).

**Consequence:** `RuntimeInstallerModel.prepareInstaller()` downloads the
*signed* `.pkg` when both are present. `GitHubRelease.installerPackage`'s doc
comment now states the two-asset fact explicitly so a future asset-naming
change on apple/container's side isn't silently mishandled again.
