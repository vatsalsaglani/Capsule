# Swift / packaging decisions and gotchas (scaffold session)

**Context:** initial project scaffold on Swift 6.2.4 / Xcode 26.3.

## Findings

1. **Monorepo shape:** one root `Package.swift` (name `CapsuleKit`) with one
   target per module beats the plan's original "one package per module" —
   same enforced boundaries via target dependencies, one manifest, and
   `swift build` / `swift test` work from the repo root. The app is an
   XcodeGen-generated project (`App/project.yml` → `App/Capsule.xcodeproj`,
   git-ignored) that references the root package via `path: ..` —
   the isowords layout.

2. **YAML "Norway problem" is real in compose files:** Yams (YAML 1.1)
   parses unquoted `no` as `Bool(false)`, so `restart: no` never arrives as a
   string. `RestartMode.init(from:)` decodes Bool-false → `.no` explicitly.
   Expect the same for `on`/`off`/`yes` values elsewhere — decode via
   `FlexibleString` which stringifies scalars.

3. **`Process` + pipes under Swift 6 strict concurrency:** `Process` is not
   Sendable. Pattern that works warning-free: `readabilityHandler` +
   `terminationHandler` feed a lock-guarded `@unchecked Sendable` coordinator
   that resumes a continuation only when *both* pipes hit EOF *and*
   termination fired — resuming on termination alone truncates output (the
   exit can race the last pipe reads). Timeout = `withThrowingTaskGroup` race;
   cancellation calls `process.terminate()` (SIGTERM only for now — SIGKILL
   escalation is a TODO tied to spike S5).

4. **`String.append` needs `contentsOf:` for `Substring`** — the only compile
   error in the initial scaffold. Trivial, but a reminder that Substring slices
   don't auto-append.

5. **App is deliberately NOT sandboxed** (`App/project.yml`): it must exec
   `/usr/local/bin/container`, which talks XPC to `container-apiserver`; App
   Sandbox breaks that chain. Distribution is Developer ID + notarization.
   Revisit only if an MAS build ever matters.

6. **App target verification without Xcode:** `xcrun swiftc -typecheck
   App/Capsule/*.swift -I .build/arm64-apple-macosx/debug/Modules -target
   arm64-apple-macosx26.0 -parse-as-library -swift-version 6` typechecks the
   SwiftUI sources against built package modules — useful pre-commit check
   when xcodegen isn't installed.

## Consequences

- Keep all new modules as targets in the root `Package.swift`.
- Never hand-edit `App/Capsule.xcodeproj`; change `App/project.yml` and
  regenerate.
- Compose scalar decoding always goes through `FlexibleString`/explicit Bool
  handling, never bare `decode(String.self)` on user-authored values.
