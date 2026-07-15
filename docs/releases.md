# Maintainer release guide

This file is intentionally excluded from the public documentation site. Capsule
releases are initiated only by a branch push; maintainers do not create or push
tags manually.

## Publish a version

Start from a commit that has already passed the `CI` workflow on `main`:

```sh
git switch main
git pull --ff-only
git switch -c release/v0.1.0-beta
git push -u origin release/v0.1.0-beta
```

The release workflow then:

1. Derives and validates SemVer from the branch.
2. Requires a successful `main` CI run for that exact commit.
3. Stamps the full version into the CLI, bundle metadata, and `VERSION`.
4. Builds and verifies the app ZIP, DMG, CLI archive, and checksums.
5. Creates the GitHub-required tag automatically.
6. Publishes the release; a suffix such as `-beta`, `-rc.1`, or `-preview.2` makes it a pre-release.
7. Rebuilds and deploys this documentation site to GitHub Pages.

## Version rules

Accepted branches use:

```text
release/v<major>.<minor>.<patch>
release/v<major>.<minor>.<patch>-<prerelease>
```

Examples:

| Branch | Result |
|---|---|
| `release/v0.1.0` | Stable `v0.1.0` release |
| `release/v0.1.0-beta` | `v0.1.0-beta` pre-release |
| `release/v0.1.0-rc.1` | `v0.1.0-rc.1` pre-release |

Published versions are immutable. If a branch changes after its version has been released, choose a new version instead of moving the existing release tag.

!!! info "GitHub still stores a tag"
    GitHub Releases are tag-backed. Capsule’s workflow creates that implementation-detail tag itself, so release authors only work with branches.
