# P4 — Polish & public v0.1.0

Sequential final pass, single worktree, after all other packages merge.
This package has **hard user-decision gates** — an agent running it must stop
and ask at each ⛔.

| | |
|---|---|
| Branch | `phase/p4-polish-release` |
| Depends on | everything else merged |
| Owns | repo-wide (nothing else is in flight) |

**Read first:** `AGENTS.md` (rules 9, 10 and the release section — **never tag
or publish without being asked**); master plan §6 (the spec being audited
against) and §5 M4; `docs/ROADMAP.md` Phase 4 checklist.

## Deliverables

1. **Design pass to §6 spec:** run `improve-animations` for the prioritized
   motion audit, execute its plans; verify color-token usage (accent ≠ state
   everywhere — grep for misuse), typography (tabular numerals, Dynamic Type
   survival), materials rules (no stacked translucency; logs/terminal solid).
2. **Accessibility audit:** reduce-motion → cross-fades, reduce-transparency →
   solid surfaces, increase-contrast borders, full keyboard nav, VoiceOver
   labels on every state dot and action. Fix, don't file.
3. **Honest compatibility docs:** generate the compose-compatibility table
   from `SupportScanner`'s key sets (supported / deferred / unsupported) so
   docs can't drift from code; README quickstart with real screenshots; demo
   recording script around `compose plan` → `up`.
4. **Error/crash reporting:** every user-facing error carries the underlying
   stderr one disclosure away (§6.1); decide crash reporting approach
   (⛔ ask the user — privacy posture is theirs to choose).
5. **Distribution:**
   - CLI: Homebrew tap formula (bottle from the release tar.gz); document
     `brew install <tap>/capsule`.
   - App: Developer ID signing + notarization + dmg in
     `.github/workflows/release.yml` (⛔ needs the user's signing identity and
     secrets — request them, never fabricate).
   - Sparkle appcast groundwork only (feed URL + keys decision documented,
     integration is v0.2).
6. ⛔ **License:** must be chosen by the user before the repo goes public
   (AGENTS release section). Present 2–3 options with implications, wait.
7. **Release:** changelog from merged PRs, `v0.1.0` tag ⛔ only on explicit
   user go-ahead; verify the draft release assets (CLI tar.gz + checksums +
   dmg) before announcing.

## Verification

Fresh-machine simulation: clone → README build steps work verbatim; dmg
installs and launches on a clean user account; `brew install` of the tap
works; the §6.5 accessibility matrix passes; `swift test` and CI green on the
release commit.

## Out of scope

New features of any kind · LaunchAgent/XPC (v0.2 roadmap) · marketing site
content beyond the README/docs.
