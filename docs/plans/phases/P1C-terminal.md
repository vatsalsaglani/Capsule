# P1C — Terminal (TerminalKit + exec sessions)

Interactive shell into any container, native SwiftTerm quality.

| | |
|---|---|
| Branch | `phase/p1c-terminal` |
| Depends on | P0-S3 decision (PTY spawn path, SwiftTerm viability); P1A Contract PR |
| Blocks | nothing (P1B ships without it if needed) |
| Owns | `Sources/TerminalKit/`, new `Tests/TerminalKitTests/`, `App/Capsule/Terminal*`, the SwiftTerm dependency lines in `Package.swift` (append-only) |

**Read first:** `AGENTS.md` (rules 1–3, skill routing → `swift-concurrency-pro`
for the session actor, `swiftui-expert-skill` for the view wrapper); master
plan §3 "Terminal" row; `docs/spikes/S3-*.md` (the decision you implement);
learnings §3 (subprocess pattern — PTY spawn differs, document how).

## Deliverables

1. **`PTYExecSession`** implementing the existing `TerminalSession` protocol:
   spawns `container exec -it <id> <shell>` under a PTY per the S3 decision,
   bridges bytes both ways (`output` AsyncStream, `send`, `resize` →
   TIOCSWINSZ, `terminate` with the S5 escalation contract). No SwiftTerm
   import inside TerminalKit if S3 chose raw PTY — keep the UI dependency in
   App; if S3 chose SwiftTerm's process handling, isolate it behind the
   protocol so the module stays UI-free enough for CLI reuse later.
2. **Shell detection:** try `sh`→`bash`→`ash` in order (master plan §3);
   surface which one connected.
3. **App terminal tab:** SwiftTerm view wired to the session; per-container
   session tabs; solid dark surface (design rule — terminals are never
   translucent); ctrl-c/resize/colors verified against a real alpine + a real
   debian container.
4. Session lifecycle: container stops → session shows a clear "exited" state,
   no zombie processes (verify with `ps`).
5. Unit tests for everything not needing a real PTY (shell fallback order,
   session state machine) against a scripted fake.

## Verification

`swift build && swift test`; app build; manual: open terminal into nginx
container, run `top`, resize the window (columns update), ctrl-c interrupts,
`exit` closes the tab cleanly; two simultaneous sessions to different
containers don't cross streams.

## Out of scope

Non-interactive `exec` (P1A owns it) · `capsule compose exec` CLI (P2B) ·
log viewers (P1B).
