# Branch-driven releases and GitHub Pages

**Context:** Capsule maintainers should publish by pushing a
`release/v<semver>` branch, without manually creating or managing tags. The
same release should stamp every product version, publish verified artifacts,
and rebuild the documentation site.

**Finding:** GitHub Releases are inherently tag-backed. `gh release create`
can create a missing tag automatically, but a branch-only maintainer workflow
cannot make the underlying GitHub tag cease to exist. Capsule therefore
creates and pushes a lightweight `v<semver>` tag inside the workflow. The tag
is an implementation detail, not a maintainer trigger.

Checking only whether the latest `main` CI run succeeded is insufficient: a
release branch could point to a different commit. The Actions API result must
contain a completed, successful `push` run whose `head_sha` exactly equals the
release branch's triggering SHA.

The CI-approved commit cannot already know the future branch version. Capsule
stamps only `VERSION`, the CLI version literal, and XcodeGen app version fields
in a deterministic child commit. The workflow rebuilds and verifies the full
product from that tree, then tags the child commit. This keeps GitHub's source
archives version-correct while preserving the CI-approved commit as its
parent. Re-running the workflow produces the same child commit identity.

`CFBundleShortVersionString` is kept as three period-separated integers.
Prerelease identity such as `0.1.0-beta` lives in the CLI and the custom
`CapsuleReleaseVersion` bundle key; putting the suffix directly in the
marketing version would create invalid Apple bundle metadata.

Xcode 26's generated Info.plist did not emit an arbitrary
`INFOPLIST_KEY_CapsuleReleaseVersion` build setting. The release rehearsal
failed at `plutil -extract CapsuleReleaseVersion` even though the setting was
visible in the project. Capsule uses a tracked explicit `Info.plist` instead;
its `CapsuleReleaseVersion` value expands the stamped
`CAPSULE_RELEASE_VERSION` build setting. Do not move this key back to generated
Info.plist settings without re-running the packaged-app extraction check.

A custom GitHub Pages workflow requires `pages: write` and `id-token: write`
for deployment, the `github-pages` environment, a configured Pages artifact,
and one repository setting selecting **GitHub Actions** as the Pages source.
Capsule builds docs in ordinary `main` CI and deploys the docs from the newly
released tag, so the public site describes the release that was just shipped.

**Verification commands:**

```sh
scripts/test-release-versioning.sh
mkdocs build --strict
scripts/package-alpha.sh v0.0.1 dist
(cd dist && shasum -a 256 -c checksums.txt)
```

**Consequence:** release authors only create `release/v<semver>` branches from
green `main` commits. Stable versions have no suffix; any accepted suffix is a
GitHub pre-release. Published tags are immutable, release artifacts carry the
same full version, and the docs rebuild only after artifact publication.
