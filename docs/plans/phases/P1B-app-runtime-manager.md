# P1B — App runtime-manager screens

Containers (full), Images, System screens + menu-bar extra; the app becomes a
usable Docker-Desktop-replacement for single containers.

| | |
|---|---|
| Branch | `phase/p1b-app-runtime-manager` |
| Depends on | P1A **Contract PR** (start immediately after it, against `FakeContainerRuntime`); P1A full merge for live data; S4 for stats cadence |
| Blocks | P4 design polish baseline |
| Owns | `App/Capsule/` **except** `Terminal*` (P1C), `Onboarding/` (P1D), `Compose/` (P2B); `App/project.yml` |

**Read first:** `AGENTS.md` (rules 1, 9 + skill routing); master plan §3
(screen/action/command table — it is the spec), §6 (the entire design system:
layout, motion, typography, color tokens, accessibility). Skills:
`swiftui-expert-skill` **before writing views**, `apple-design` for the feel
prototype, `swift-charts` for sparklines, `swiftui-pro` review before merge.

## Deliverables

1. **Feel prototype first (2–3 days, master plan §6.6):** sidebar/list/
   inspector + one live-updating container row, driven by a scripted
   `FakeContainerRuntime` that changes states on a timer. Critically damped
   springs (`response 0.35, dampingFraction 1.0`), state-dot color+scale pulse
   on transitions, interruptible inspector slide. This sets the craft bar —
   review it frame-by-frame before building everything else on it.
2. **Containers screen, full:** list backed by the EventBus/Poller (kill the
   ViewModel's own polling loop once P1A lands); inspector panel (image, IPs,
   published ports, env, mounts); actions per row (start/stop/kill/restart/
   delete, copy files, open-in-browser derived from port mappings); logs tab
   with follow + solid-dark log surface (§6.2 — logs never translucent);
   CPU/mem sparkline via `swift-charts` at the S4-decided cadence.
3. **Images screen:** list with sizes, pull-with-progress sheet, tag, delete,
   prune (confirmation only for the truly irreversible — §6.1 forgiveness
   rules), inspect layers.
4. **System screen:** runtime status/version, `system df` storage, start/stop
   runtime, DNS domains list (sudo ops = copy-command flow, never shell sudo
   — master plan §3).
5. **Menu-bar extra, real:** runtime up/down dot, N running, stop-all — fed by
   the same EventBus stream.
6. ViewModels stay logic-free (AGENTS rule 1): anything beyond
   subscribe/format/dispatch moves into CapsuleKit; ViewModel tests run
   against `FakeContainerRuntime`.

## Design constraints (non-negotiable, from §6)

Accent indigo ≠ state; state = systemGreen/Orange/Red/Gray only ·
`accessibilityReduceMotion` → cross-fades · sidebar material translucent,
content plain, log/terminal surfaces solid `#161618` · tabular numerals for
ports/IPs/sizes · VoiceOver labels on state dots ("api — running, healthy,
port 8080").

## Verification

`xcodegen generate --spec App/project.yml --project App` + Debug build; run
against the real runtime: start/stop/delete a scratch nginx container from the
UI, watch it live-update within 2 s; kill the apiserver → graceful
"runtime unavailable" state, restart → recovery without relaunch. `swiftui-pro`
checklist pass on the final diff. Screens still render at largest Dynamic Type.

## Out of scope

Terminal tab (P1C) · onboarding/install flow (P1D) · Compose screen (P2B) ·
Volumes/Networks/Builds/Machines screens (P3 wave — leave the placeholders).
