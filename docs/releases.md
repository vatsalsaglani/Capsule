# Branch-driven releases

Capsule releases are initiated only by a branch push. You do not create or push tags manually.

<div class="release-lab" data-release-branch>
  <div class="release-lab__header">
    <div>
      <span class="capsule-kicker">RELEASE PREVIEW</span>
      <h2>What will this branch publish?</h2>
    </div>
    <span class="release-lab__state" data-release-state>Pre-release</span>
  </div>
  <label for="release-branch">Branch name</label>
  <input id="release-branch" data-release-input value="release/v0.1.0-beta" spellcheck="false" autocomplete="off">
  <p class="release-lab__error" data-release-error hidden></p>
  <dl>
    <div><dt>Version</dt><dd data-release-version>0.1.0-beta</dd></div>
    <div><dt>GitHub release</dt><dd data-release-tag>v0.1.0-beta</dd></div>
    <div><dt>Classification</dt><dd data-release-kind>Pre-release</dd></div>
    <div><dt>App artifact</dt><dd data-release-asset>Capsule-v0.1.0-beta.dmg</dd></div>
  </dl>
</div>

## Publish

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

## One-time Pages setting

In the GitHub repository, choose **Settings → Pages → Build and deployment → Source: GitHub Actions**. The release workflow handles every subsequent documentation build and deployment.
