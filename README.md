# Capsule

**A native macOS container manager with Compose-style project orchestration
for Apple's [`container`](https://github.com/apple/container) runtime.**

SwiftUI app (`Capsule.app`) + companion CLI (`capsule`) sharing one engine
(CapsuleKit). What Docker Desktop/Podman Desktop are for their runtimes — plus
a compose translator/supervisor built on `container`'s native volumes,
networks, and port publishing.

> **Status: pre-alpha scaffold.** Nothing is released yet. See
> [docs/ROADMAP.md](docs/ROADMAP.md) for the phase plan and
> [docs/plans/apple-container-manager-plan.md](docs/plans/apple-container-manager-plan.md)
> for the full product/architecture plan.

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

## Run the pre-built app (unsigned)

Every push to `main` builds `Capsule.app` via the **App Artifact** workflow and
uploads it as a downloadable artifact (tagged `v*` builds also attach it to the
drafted release). There is **no notarized build yet** — that's a Phase 4
deliverable — so the app is unsigned (ad-hoc only) and macOS Gatekeeper will
block it until you clear the download quarantine and self-sign it once:

```sh
# 1. Grab the artifact: GitHub → Actions → "App Artifact" → latest run →
#    download "Capsule.app-<sha>", then unzip it.
unzip Capsule.app.zip

# 2. Remove the quarantine flag the browser added on download
#    (without this, Gatekeeper refuses to open an unsigned app).
xattr -dr com.apple.quarantine Capsule.app

# 3. Ad-hoc self-sign it (the CI build is unsigned and NOT notarized —
#    you are vouching for it on your own machine).
codesign --force --deep --sign - Capsule.app

# 4. Launch it.
open Capsule.app
```

You still need the [`container`](https://github.com/apple/container/releases)
runtime installed — if it's missing, Capsule's onboarding screen offers to
download the installer for you (it never runs the installer itself).

> Until notarization lands, treat this as a developer preview: only run a build
> you trust, ideally one you produced from source or from this repo's CI.

## Repo layout

| Path | What |
|---|---|
| `Sources/` | CapsuleKit modules — all business logic (ContainerClient, EventBus, AppCore, TerminalKit, RuntimeInstaller, ComposeSpec, ComposePlanner, ComposeRuntime, Supervisor, ProjectStore) |
| `Sources/CapsuleCLI/` | `capsule` executable (thin frontend) |
| `App/` | SwiftUI app (thin frontend — views bind to `AppCore` stores) + XcodeGen spec |
| `assets/` | brand assets (app icon, menu-bar mark, wordmark) → `App/Capsule/Assets.xcassets` |
| `Tests/`, `Fixtures/` | unit tests + golden compose fixtures |
| `docs/` | plan, roadmap, spike results, learnings |
| `AGENTS.md` | working agreements for humans and AI agents |

Honest scoping: Capsule supports a documented compose subset and reports every
unsupported key (`capsule compose config`) — it does not claim
`docker-compose.yml` compatibility beyond that.

License: TBD before the first public release.
