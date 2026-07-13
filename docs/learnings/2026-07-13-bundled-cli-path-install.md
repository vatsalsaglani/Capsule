# Bundling Capsule's CLI and installing its PATH link

**Context:** adding an in-app button that makes the existing `capsule` CLI
available to Terminal without editing a user's shell startup files.

**Finding:** `Capsule.app/Contents/MacOS/Capsule` and a second executable named
`capsule` cannot safely coexist in `Contents/MacOS` on the case-insensitive
filesystem used by normal macOS installations. The production CLI must be a
separate Xcode target built from `Sources/CapsuleCLI` and embedded as signed
nested code at `Contents/Helpers/capsule`; copying `.build/debug/capsule` would
both package the wrong configuration and bypass Xcode's dependency/signing
graph.

XcodeGen 2.45.4 supports this directly as a target dependency with a custom
Copy Files destination (`wrapper`, subpath `Contents/Helpers`). Verified on
Xcode 26.3 with:

```sh
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/Capsule.xcodeproj -scheme Capsule \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath dist/CLIPathDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build

dist/CLIPathDerivedData/Build/Products/Release/Capsule.app/Contents/Helpers/capsule --version
# 0.1.0-dev

file dist/CLIPathDerivedData/Build/Products/Release/Capsule.app/Contents/Helpers/capsule
# Mach-O universal binary with 2 architectures: x86_64 and arm64
```

**Consequence:** Capsule manages only the fixed
`/usr/local/bin/capsule` symlink. It validates the helper is a regular,
executable file whose lexical and resolved paths remain inside the app bundle;
uses `lstat`/`readlink` so dangling and relative destination links are visible;
and never overwrites a regular file, directory, or foreign symlink. A stale
link to an older `Capsule.app/Contents/Helpers/capsule` requires explicit
confirmation and revalidation. Permission failures show a safely shell-escaped
sudo command for the user to review and paste; the app never invokes sudo and
never edits `.zshrc` or `.zprofile`.
