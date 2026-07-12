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

## Repo layout

| Path | What |
|---|---|
| `Sources/` | CapsuleKit modules — all business logic (ContainerClient, ComposeSpec, ComposePlanner, ComposeRuntime, Supervisor, ProjectStore, EventBus, TerminalKit) |
| `Sources/CapsuleCLI/` | `capsule` executable (thin frontend) |
| `App/` | SwiftUI app (thin frontend) + XcodeGen spec |
| `Tests/`, `Fixtures/` | unit tests + golden compose fixtures |
| `docs/` | plan, roadmap, spike results, learnings |
| `AGENTS.md` | working agreements for humans and AI agents |

Honest scoping: Capsule supports a documented compose subset and reports every
unsupported key (`capsule compose config`) — it does not claim
`docker-compose.yml` compatibility beyond that.

License: TBD before the first public release.
