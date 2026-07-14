# Capsule

**A native macOS container manager with Compose-style project orchestration
for Apple's [`container`](https://github.com/apple/container) runtime.**

SwiftUI app (`Capsule.app`) + companion CLI (`capsule`) sharing one engine
(CapsuleKit). What Docker Desktop/Podman Desktop are for their runtimes — plus
a compose translator/supervisor built on `container`'s native volumes,
networks, and port publishing.

> **Status: developer preview.** Release branches now produce versioned GitHub
> releases, while Developer ID signing and notarization remain Phase 4 work. See
> [docs/ROADMAP.md](docs/ROADMAP.md) for the phase plan and
> [docs/plans/apple-container-manager-plan.md](docs/plans/apple-container-manager-plan.md)
> for the full product/architecture plan.

The project documentation is built with MkDocs and published after each
release at [vatsalsaglani.github.io/Capsule](https://vatsalsaglani.github.io/Capsule/).

## Requirements

- macOS 26 (Tahoe), Apple silicon
- [`container`](https://github.com/apple/container/releases) 1.x
  (`capsule doctor` checks your install and tells you about updates)
- Xcode 26 / Swift 6.2 to build

## Build

```sh
# Engine + CLI
swift build
swift test
swift run capsule doctor
swift run capsule compose plan -f Fixtures/compose/basic-web-db.yaml

# App (project is generated, never committed)
brew install xcodegen
xcodegen generate --spec App/project.yml --project App
open App/Capsule.xcodeproj
```

See the [CLI command reference](docs/CLI.md) for every implemented command,
option, default, and the enforced Compose compatibility table.

## Run a pre-built app

Pushes to `release/v<version>` publish an app ZIP, DMG, standalone CLI archive,
and SHA-256 checksums. Pushes to `main` also upload a short-lived app artifact
from the **App Artifact** workflow. There is **no notarized build yet** — that's
a Phase 4 deliverable — so these apps are ad-hoc signed and macOS Gatekeeper
may block a downloaded copy until you clear quarantine once:

```sh
xattr -dr com.apple.quarantine /Applications/Capsule.app
open /Applications/Capsule.app
```

Only remove quarantine from an artifact you trust. Release downloads can be
checked against their attached `checksums.txt` before launch.

You still need the [`container`](https://github.com/apple/container/releases)
runtime installed — if it's missing, Capsule's onboarding screen offers to
download the installer for you (it never runs the installer itself).

> Until notarization lands, treat this as a developer preview: only run a build
> you trust, ideally one you produced from source or from this repo's CI.

## Publishing a release

Release authors create a branch from an exact commit that has passed `CI` on
`main`; they never create a tag manually:

```sh
git switch main
git pull --ff-only
git switch -c release/v0.1.0-beta
git push -u origin release/v0.1.0-beta
```

The workflow derives the version, stamps the CLI and app, builds and verifies
all artifacts, marks suffixed versions as pre-releases, creates GitHub's
required implementation-detail tag, publishes release notes, and deploys the
docs. See the [release guide](docs/releases.md) for the exact contract.

## Repo layout

| Path | What |
|---|---|
| `Sources/` | CapsuleKit modules — all business logic (ContainerClient, EventBus, AppCore, TerminalKit, RuntimeInstaller, Diagnostics, ComposeSpec, ComposePlanner, ComposeRuntime, Supervisor, ProjectStore) |
| `Sources/CapsuleCLI/` | `capsule` executable (thin frontend) |
| `App/` | SwiftUI app (thin frontend — views bind to `AppCore` stores) + XcodeGen spec |
| `assets/` | brand assets (app icon, menu-bar mark, wordmark) → `App/Capsule/Assets.xcassets` |
| `Tests/`, `Fixtures/` | unit tests + golden compose fixtures |
| `docs/` | plan, roadmap, spike results, learnings |
| `AGENTS.md` | working agreements for humans and AI agents |

Honest scoping: Capsule supports a documented compose subset and reports every
unsupported key (`capsule compose config`) — it does not claim
`docker-compose.yml` compatibility beyond that.

Licensed under the [Apache License 2.0](LICENSE), matching Apple's
`container` project.
