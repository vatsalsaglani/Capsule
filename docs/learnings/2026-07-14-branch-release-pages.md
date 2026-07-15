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

`actions/setup-python@v6` does not discover Capsule's nonstandard
`requirements-docs.txt` filename when `cache: pip` is enabled. Without an
explicit `cache-dependency-path: requirements-docs.txt`, setup fails before the
install step while reporting that neither `requirements.txt` nor
`pyproject.toml` exists—even when `requirements-docs.txt` is present in the
checked-out release. Every documentation job must name that cache dependency
path explicitly.

Re-running a failed Actions run keeps the original trigger SHA and its workflow
definition, so a workflow fix on `main` cannot repair a documentation job that
already failed after publishing an immutable release tag. Capsule therefore
has a docs-only manual recovery workflow: maintainers provide the familiar
`release/v<semver>` branch name, while the workflow derives and checks out the
workflow-owned tag internally before rebuilding and deploying Pages.

The same recovery path also supports a reviewed documentation-only correction
after publication. Its optional documentation ref may point at an exact commit
from `main`; when omitted it still defaults to the immutable release tag. This
lets maintainers repair public presentation or accessibility without moving the
tag or replacing app/CLI artifacts. Use an exact commit SHA, not a floating
branch name, so the deployed documentation remains auditable.

GitHub evaluates a job's `github-pages` environment protection against the
workflow's triggering ref, not the source ref later checked out by
`actions/checkout`. Capsule's Pages environment was initially restricted to
`develop`, so a fully successful release from `release/v0.1.3-beta` built its
documentation and was then rejected before deployment. The repository default
branch and environment rules must agree with the release workflow: `main` is
the default branch, while `github-pages` permits both `main` and the custom
branch pattern `release/*`. GitHub's environment wildcards do not cross `/`;
`release/*` is therefore the deliberate one-slash match for Capsule's
`release/v<semver>` branches.

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
same full version, and the docs rebuild only after artifact publication. A
failed Pages deployment can be recovered without rebuilding or replacing the
release artifacts. Repository environment policy is part of the release
contract and must continue allowing `main` plus `release/*`. Post-release
documentation-only corrections deploy from an exact reviewed source SHA while
leaving the published tag and binary assets unchanged.
