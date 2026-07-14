# Get started

Capsule currently targets macOS 26 and Apple’s `container` 1.x runtime. The app is native SwiftUI; the CLI and CapsuleKit engine use Swift 6.

## Requirements

- macOS 26 (Tahoe)
- Apple silicon for the standalone CLI archive
- [`container` 1.x](https://github.com/apple/container/releases)
- Xcode 26 and Swift 6.2 when building from source

## Build from source

```sh
git clone https://github.com/vatsalsaglani/Capsule.git
cd Capsule

# CapsuleKit + CLI
swift build
swift test
swift run capsule doctor

# Native app
brew install xcodegen
xcodegen generate --spec App/project.yml --project App
open App/Capsule.xcodeproj
```

The generated `App/Capsule.xcodeproj` is intentionally ignored. Change `App/project.yml`, then regenerate.

## Try a Compose project

Review the resolved configuration and execution plan before mutating the runtime:

```sh
swift run capsule compose config --report \
  -f Fixtures/compose/basic-web-db.yaml

swift run capsule compose plan \
  -f Fixtures/compose/basic-web-db.yaml

swift run capsule compose up -d \
  -f Fixtures/compose/basic-web-db.yaml
```

Use `capsule compose ps`, `logs`, `stop`, `start`, `restart`, and `down` for the project lifecycle. The [CLI reference](CLI.md) documents the complete implemented surface.

## Install a GitHub release

Release branches publish an app ZIP, DMG, CLI archive, and checksums. Until Developer ID notarization lands:

1. Download and open the DMG.
2. Copy `Capsule.app` to `/Applications`.
3. If you trust the artifact, clear its quarantine attribute once:

```sh
xattr -dr com.apple.quarantine /Applications/Capsule.app
```

4. Launch Capsule.

Verify downloaded assets from the same release directory:

```sh
shasum -a 256 -c checksums.txt
```

!!! warning "Why the quarantine step exists"
    These developer-preview artifacts are ad-hoc signed, not notarized. Removing quarantine opts this local copy out of Gatekeeper’s download check. It is not a substitute for verifying the source and checksum.

## Put `capsule` in your PATH

The app bundles its matching CLI in `Capsule.app/Contents/Helpers/capsule`. The System screen can install a validated `/usr/local/bin/capsule` symlink. Capsule never edits shell profiles and never invokes `sudo` itself.
