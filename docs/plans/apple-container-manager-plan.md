# Capsule — Native macOS Container Manager + Compose for Apple `container`

***Capsule** — app: Capsule.app, CLI: `capsule`.*

A native SwiftUI macOS app + companion CLI that does for Apple's `container` what Docker Desktop/Podman Desktop do for their runtimes — plus a Compose-style orchestrator (`capsule compose`) built on `container`'s native volumes, networks, and port publishing.

---

## 0. Ground truth (as of July 2026) — what changed since the original discussion

The earlier chat assumed a pre-1.0 runtime with no ports, no volumes, no networks. That is no longer true. Verified against `apple/container` v1.0 docs:

| Capability | Pre-1.0 assumption | v1.0 reality |
|---|---|---|
| Stability | Breaking changes anytime | **v1.0.0 (June 9, 2026)** — CLI + XPC APIs frozen within 1.0.x |
| Ports | IP-per-container only; build your own proxy | Native `-p/--publish [host-ip:]host:container[/proto]` and `--publish-socket` |
| Volumes | Bind mounts only | `container volume create/ls/inspect/rm/prune` + `-v` and `--mount type=volume` |
| Networks | Single shared vmnet | `container network create` (subnets, `--internal`, labels; macOS 26+) |
| DNS | Host-side `/etc/resolver` domains only | Plus per-container `--dns`, `--dns-domain`, `--dns-search`, `--dns-option` |
| Labels | — | `-l key=val` on containers, volumes, networks (our project-tracking backbone) |
| Persistent VMs | — | `container machine` (long-lived Linux dev VMs) |
| Restart policy | Missing | **Still missing** → we implement |
| Healthchecks | Missing | **Still missing** → we implement |
| Compose | Missing | **Still missing natively** → our core value |
| Docker Engine API socket | Requested | Closed as "not planned" → real `docker compose` will never just work; a translator is the durable niche |

**Consequences for the plan:**
1. The Compose engine becomes a **translator + supervisor**, not a re-implementation of networking/ports/volumes. Much smaller surface, much faster MVP.
2. The frozen XPC/Swift API means we can (eventually) talk to the runtime **in-process via Apple's Swift packages** instead of shelling out — but only pin to 1.0.x.
3. Restart policies + healthchecks + `depends_on: service_healthy` are ours to build — this is a *supervisor daemon* concern, and it forces a background-agent decision early (see §4.6).

**Competitive landscape (differentiate, don't ignore):** community compose CLIs exist (`Mcrich23/Container-Compose` in Swift, `us/mocker` — a Docker-compatible CLI + compose + menu-bar app on the Containerization framework), and several GUIs (Orchard, Container Desktop, AppleContainerGUI, iContainer). All are early/immature. Our wedge: **the only product where a polished native GUI and a compose CLI share one engine**, with genuinely Apple-grade interaction design (see §6) — not an Electron shell, not a CLI with a status bar.

---

## 1. Product definition

### Positioning (v1)
> **A native macOS container manager with Compose-style project orchestration for Apple `container`.**

Explicitly *not* (yet): "a drop-in Docker Desktop replacement." Do not claim `docker-compose.yml` compatibility beyond the documented supported subset. Print a clear "unsupported key: X (ignored / fatal)" report on every `up`.

### Users & jobs
- **Mac-native developer**: runs Postgres/Redis/nginx + their app locally; wants `capsule compose up`, logs, a terminal, and to never open Docker Desktop again.
- **Apple-silicon team lead**: wants no Docker Desktop licensing, likes per-container VM isolation.
- **You (dogfood)**: multi-service stacks (API + DB + queue + mock services) for day-to-day local development — every feature must survive daily personal use before it ships.

### Non-goals (v1)
Kubernetes, Dev Containers spec, Docker Engine API socket emulation, Swarm, remote hosts, Intel Macs, macOS < 26.

---

## 2. System architecture

```text
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  Capsule.app (SwiftUI)       │   │  capsule CLI (swift-argument- │
│  Containers/Images/Compose/  │   │  parser): compose up/down/ps/ │
│  Volumes/Networks/Builds/    │   │  logs/build/pull/config …    │
│  System + Menu-bar extra     │   │                              │
└──────────────┬───────────────┘   └──────────────┬───────────────┘
               │        (both are thin frontends) │
               ▼                                  ▼
        ┌─────────────────────────────────────────────────┐
        │              CapsuleKit (SPM packages)          │
        │  ContainerClient   → runtime access (protocol)  │
        │  ComposeSpec       → YAML → typed model         │
        │  ComposePlanner    → model → DAG plan           │
        │  ComposeRuntime    → plan execution + reconcile │
        │  Supervisor        → restart policy + health    │
        │  ProjectStore      → state, logs index, events  │
        │  TerminalKit       → PTY/exec sessions          │
        │  EventBus          → async event streams        │
        └───────────────────────┬─────────────────────────┘
                                │
              ┌─────────────────┴──────────────────┐
              │ ContainerClient implementations    │
              │  A) CLIProcessClient (MVP)         │
              │     Process → /usr/local/bin/      │
              │     container … --format json      │
              │  B) XPCClient (post-MVP)           │
              │     apple/container Swift pkgs,    │
              │     pinned to 1.0.x                │
              └─────────────────┬──────────────────┘
                                │
                     Apple container runtime
                     (one lightweight VM per container)
```

### 2.1 Repo layout (Swift Package monorepo + Xcode app target)

```text
capsule/
├── Capsule.xcodeproj              # app + menu-bar extra targets
├── App/                           # SwiftUI app (views, view models only)
├── Packages/
│   ├── ContainerClient/           # protocol + CLIProcessClient + (later) XPCClient
│   ├── ComposeSpec/               # Yams decode, interpolation, .env, validation
│   ├── ComposePlanner/            # normalization, DAG, diffing, plan rendering
│   ├── ComposeRuntime/            # executor: pull/build/create/start, reconcile
│   ├── Supervisor/                # restart policies, healthchecks, watchers
│   ├── ProjectStore/              # ~/Library/Application Support/Capsule/…
│   ├── EventBus/                  # AsyncStream-based domain events
│   └── TerminalKit/               # SwiftTerm-backed exec/PTY sessions
├── CLI/                           # `capsule` executable (ArgumentParser)
├── Fixtures/                      # compose files for tests (golden plans)
└── Tests/
```

Rule: **App/ and CLI/ contain zero business logic.** Every feature must be drivable from a unit test against CapsuleKit.

### 2.2 Runtime access strategy: CLI first, protocol always

Start with subprocess wrapping (fast, matches the frozen public CLI, easy to debug — every action is reproducible in a terminal). But hide it behind a protocol from day one:

```swift
protocol ContainerRuntime: Sendable {
    func listContainers(all: Bool) async throws -> [ContainerSummary]
    func inspect(_ id: String) async throws -> ContainerDetail
    func run(_ spec: RunSpec) async throws -> String            // returns container id
    func stop(_ id: String, timeout: Duration?) async throws
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<LogLine, Error>
    func stats(_ ids: [String]) -> AsyncThrowingStream<StatsSample, Error>
    func exec(_ id: String, argv: [String], tty: TTYOptions?) async throws -> ExecSession
    func events() -> AsyncStream<RuntimeEvent>                  // synthesized by polling in MVP
    // images, volumes, networks, system, build …
}
```

Subprocess rules (unchanged from the original discussion, still correct):
- `Process` with argv arrays. **Never** interpolate into a shell string.
- Prefer `--format json` everywhere it exists; keep a table-parser fallback with a version check.
- Stream via `FileHandle.bytes` for `logs --follow`, `build`, `stats`; wrap in `AsyncThrowingStream` with backpressure (drop-oldest ring buffer for UI, full spool to disk for project logs).
- Timeouts + cancellation on every call; map exit codes/stderr to typed `RuntimeError`.
- One `actor RuntimeGateway` to serialize mutating ops per resource, allow concurrent reads.
- Detect CLI version at startup (`container system version --format json`); refuse or warn on non-1.0.x.

**Post-MVP:** implement `XPCClient` against `apple/container`'s Swift packages (APIs frozen in 1.0.x) to get real event streams and lower latency; keep `CLIProcessClient` as the compatibility fallback and for `--debug parity` mode.

---

## 3. Phase 1 — Runtime manager (GUI + basic CLI)

Feature-parity checklist with "simple Docker Desktop", all backed by the v1.0 CLI:

| Screen | Data / actions | Underlying commands |
|---|---|---|
| **Containers** | list (running/all), state, image, IP(s), published ports, CPU/mem sparkline; start/stop/kill/restart/delete/prune; logs; terminal; copy files; open in browser (from `-p` mappings or container IP) | `list --all --format json`, `inspect`, `start/stop/kill/delete/prune`, `logs --follow`, `stats`, `exec -it`, `cp` |
| **Images** | list, size, pull w/ progress, tag, push, delete, prune, inspect layers | `image ls/pull/push/tag/rm/prune/inspect`, `registry login/logout/list` |
| **Builds** | pick dir, detect Dockerfile, args/tags/platform, streamed output, cancel, history; builder lifecycle | `build`, `builder start/status/stop/rm` |
| **Volumes** | list, size, labels, create, inspect, delete, prune; "used by" via container inspects | `volume create/ls/inspect/rm/prune` |
| **Networks** | list, subnet, containers attached, create (subnet/internal), delete, prune | `network create/ls/inspect/rm/prune` |
| **Machines** | list `container machine` VMs, start/stop/logs (thin v1 — table + actions) | `machine ls/run/stop/logs/inspect` |
| **System** | runtime status, versions, kernel, `system df` storage, DNS domains, start/stop runtime, log viewer | `system status/version/df/logs/start/stop`, `system dns create/ls/rm`, `system property ls` |
| **Menu-bar extra** | runtime up/down, N running, quick stop-all, per-project status dots | derived from EventBus |

Cross-cutting:
- **Terminal**: SwiftTerm view over `container exec -it <id> <shell>` PTY; shell picker (sh/bash/ash detection by trying in order); per-container session tabs.
- **Events without an events API (MVP)**: an `actor Poller` diffing `list --all` every 1–2 s (backoff when idle/window hidden) → synthesized `RuntimeEvent`s on the EventBus. Swap for real XPC events later without touching the UI.
- **Sudo-required ops** (`system dns create`): don't shell sudo from the app; show the exact command to paste in Terminal, or use an `SMAppService`/AuthorizationServices helper later. v1: copy-to-clipboard flow.

**Exit criteria for Phase 1:** manage full container/image/volume/network lifecycle without touching Terminal; logs and terminal are solid; app survives runtime restarts and CLI absence gracefully (onboarding screen with install/start guidance).

---

## 4. Phase 2 — Compose engine (`ComposeSpec` → `ComposePlanner` → `ComposeRuntime` → `Supervisor`)

### 4.1 Pipeline

```text
compose.yaml (+ overrides, + .env)
   ↓  ComposeSpec: Yams decode → interpolation → validation → SupportReport
Normalized ProjectModel (services, volumes, networks, dependencies)
   ↓  ComposePlanner: desired state vs observed state → DAG of steps
ExecutionPlan (pull/build/create-volume/create-network/start/wait-healthy/…)
   ↓  ComposeRuntime: executes steps via ContainerRuntime, emits progress events
Running project
   ↓  Supervisor: health probes, restart policies, reconcile loop
```

### 4.2 Supported subset — v1 compose schema

Support (fail loud on anything else, per-key policy: `ignore-with-warning` vs `fatal`):

- `name`, `services.*`: `image`, `build` (context/dockerfile/args/target), `command`, `entrypoint`, `environment` (map+list), `env_file`, `working_dir`, `user`, `volumes` (bind + named + `tmpfs`), `ports` (short + long syntax), `depends_on` (list + `condition: service_started|service_healthy|service_completed_successfully`), `healthcheck` (`test/interval/timeout/retries/start_period`), `restart` (`no|always|on-failure|unless-stopped`), `labels`, `networks` (attach-only), `platform`, `init`, `read_only`, `shm_size`, `tmpfs`, `stop_grace_period`
- Top-level `volumes` (named, external), `networks` (project default + named, `internal`), variable interpolation `${VAR:-default}` / `${VAR:?err}`, `.env` + `--env-file`
- Later (v1.1+): `profiles`, multiple `-f` merge, `extends`, `secrets`/`configs` (Keychain-backed), resource limits (`cpus`/`mem_limit` → `--cpus`/`--memory`), `pull_policy`, `develop.watch`

### 4.3 Direct mappings (the easy 70% — now native)

| Compose | Apple `container` |
|---|---|
| `ports: "8080:80"` | `-p 8080:80` (plus host-ip and `/udp` forms) |
| named volume `pg:/var/lib/postgresql/data` | `container volume create <proj>_pg` + `-v <proj>_pg:/var/…` |
| bind `./src:/app` | `-v $(abs)./src:/app` (+`:ro` via `--mount …,readonly`) |
| `tmpfs` | `--tmpfs` |
| project network | `container network create <proj>_default --label capsule.project=<proj>` |
| `platform: linux/amd64` | `--platform` + `--rosetta` hint |
| `init: true` | `--init` |
| env / env_file / workdir / user / entrypoint / labels | 1:1 flags |
| container identity | labels: `capsule.project`, `capsule.service`, `capsule.index`, `capsule.config-hash` |

Names deterministic: `<project>-<service>-<n>`; project = dir name unless `name:`/`-p` given.

### 4.4 Service discovery — the one genuinely open design problem

**Decided 2026-07-13 (S1):** hosts injection ships as the always-on default
(non-sudo, verified); the DNS-search-domain path is sudo-gated (`sudo
container system dns create capsule`) and unverified — demoted to an
optional upgrade. See `docs/spikes/S1-dns-service-discovery.md`. (The
"primary"/"Fallback A" ordering below predates that decision and is kept
for historical context; do not treat it as current plan of record.)

Compose apps expect bare `db:5432`. Plan of record, in order:

1. **Spike S1 (do this first, ~1 day):** two containers on one user-defined network — test what resolves out of the box: `<name>`, `<name>.<domain>`? The runtime configures container DNS; behavior on custom networks must be verified empirically on macOS 26.
2. **Primary approach — DNS search domains:** create host DNS domain per project (`container system dns create <proj>` — one-time sudo, or a single shared `capsule` domain created at install to avoid per-project sudo), run every service with `--dns-search <proj>.capsule` and container name = service name. Then `db` resolves via search-domain expansion to `db.<proj>.capsule` **with zero app changes** — if (spike-verified) the in-VM resolver answers container names under that domain for container-originated queries, not just host queries.
3. **Fallback A — hosts injection:** after IPs are known, `container exec` append `/etc/hosts` entries per service; supervisor re-injects on restart/IP change. Ugly but transparent; ship behind a flag if (2) fails.
4. **Fallback B — project DNS proxy:** tiny DNS server (SwiftNIO) on the host or in a sidecar container, set as `--dns` for all project containers, answering service names from ProjectStore. Most robust, most complexity — only if (2) and (3) both disappoint.

Whatever ships: `capsule compose config --report` must state exactly how names resolve for this project.

### 4.5 Planner

- Build DAG from `depends_on`; detect cycles → fatal with the cycle printed.
- Steps are typed and idempotent: `EnsureImage`, `EnsureBuild`, `EnsureVolume`, `EnsureNetwork`, `EnsureContainer` (create if config-hash differs → recreate), `Start`, `WaitHealthy`, `WaitStarted`.
- **Config-hash reconciliation** (the docker-compose behavior people rely on): hash the resolved per-service spec into a label; `up` recreates only services whose hash changed, restarts dependents in DAG order. `--force-recreate`, `--no-deps` escape hatches.
- `capsule compose config` prints resolved YAML; `capsule compose plan` (differentiator!) prints the step DAG before executing — plan-before-run transparency no other tool offers, and great demo material.
- Parallelize independent branches (pulls/builds concurrent; starts respect DAG).

### 4.6 Supervisor — restart policies + healthchecks (runtime doesn't have them)

- **Health probes:** `test: ["CMD", …]` → `container exec` with timeout; `CMD-SHELL` → `exec sh -c '…'`. State machine per service: `starting → healthy | unhealthy` with `interval/retries/start_period`. Gates `depends_on: service_healthy`.
- **Restart policies:** watcher on container exit events (poller/XPC) applies `always`/`on-failure[:max]`/`unless-stopped` with exponential backoff (docker-compatible: 100ms doubling, cap 1 min).
- **Where does the supervisor live?** Decision: v1 = **inside whichever frontend ran `up`** (app or CLI process). If that process exits, restart policies pause; `capsule compose up -d` from the CLI prints a notice ("supervision requires the Capsule agent"), and the app resumes supervision on next launch via reconcile. v1.1 = a proper **LaunchAgent** (`capsuled`, SMAppService) owning Supervisor + EventBus, with app/CLI as XPC clients. Design the Supervisor package agent-ready from day one (no UI imports, serializable state).
- **Reconcile on attach:** on app launch / `compose ps`, observed state (by labels) vs desired state (ProjectStore) → drift report → optional auto-heal.

### 4.7 ProjectStore

```text
~/Library/Application Support/Capsule/
├── projects/<project-id>/
│   ├── project.json           # source path, name, env-file refs
│   ├── resolved-compose.json  # last resolved model + support report
│   ├── state.json             # desired state, per-service hashes, supervisor state
│   └── logs/                  # rotated per-service spools (for project log view)
├── events.jsonl               # ring-buffered domain events (debug)
└── settings.json
```

JSON on disk, versioned schemas, atomic writes. (SQLite/GRDB only if log indexing demands it.)

### 4.8 `capsule` CLI surface

```bash
capsule compose up [-d] [--build] [--force-recreate] [--no-deps] [service…]
capsule compose down [--volumes] [--remove-orphans]
capsule compose ps | logs [-f] [service…] | build | pull | restart | stop | start
capsule compose config [--report] | plan | exec <service> <cmd…>
capsule ls | images | volumes | networks        # thin passthroughs w/ project grouping
capsule doctor                                   # runtime version, DNS setup, PATH, diagnostics
```

Exit codes and flag names mirror `docker compose` where semantics match — muscle-memory compatibility, honestly scoped.

---

## 5. Phase plan & milestones

### M0 — Spikes (1 week, before committing architecture details)
- **S1 DNS/networks** (§4.4) — decides discovery approach. *Highest risk.*
- **S2 `--format json` coverage** — which commands emit JSON; parse-stability check; catalog gaps.
- **S3 PTY/exec** — SwiftTerm + `container exec -it` interactive quality (resize, colors, ctrl-c).
- **S4 stats streaming** — `stats` output format, per-second cost of polling 10 containers.
- **S5 build streaming + cancel** — SIGINT semantics of `container build`.

### M1 — Runtime manager MVP (3–4 weeks)
ContainerClient (CLI impl) + Containers/Images/System screens, logs, terminal, menu-bar extra, onboarding/doctor. **Ship as TestFlight/dmg alpha.**

### M2 — Compose core (3–4 weeks)
ComposeSpec + Planner + Runtime for the §4.2 subset minus health/restart; `capsule compose up/down/ps/logs/config/plan`; Compose screen in app (project list, per-service status, project logs, up/down/restart, plan viewer). **This is the launch demo.**

### M3 — Supervision & fidelity (2–3 weeks)
Healthchecks, `service_healthy` gating, restart policies, config-hash recreate, drift reconcile, `.env` edge cases, volumes/networks screens, dependency-graph visualization (nice SwiftUI Canvas moment).

### M4 — Polish & public v0.1 (2 weeks)
Design pass to §6 spec, reduced-motion audit, crash/error reporting, docs site, honest compose-compatibility table, Homebrew tap for CLI, notarized dmg.

### Later (v0.2+)
LaunchAgent supervisor, XPCClient runtime, profiles/multi-file/extends, `develop.watch` file-sync rebuild, Keychain secrets, `container machine` first-class UX, Sparkle updates, plugin/extension story.

**Risks (top 3):** (1) bare-hostname DNS doesn't work container-to-container → fallbacks A/B add complexity; (2) JSON output gaps force fragile table parsing → pin CLI version, contribute `--format json` PRs upstream; (3) per-VM memory not returned to host under many containers → surface memory in UI prominently, add "restart heavy containers" affordance.

---

## 6. UI & interaction design spec (apple-design skill, translated to native SwiftUI)

The skill's principles are Apple's own (WWDC *Designing Fluid Interfaces*, *Principles of Great Design*); on macOS we implement them with first-party APIs rather than web approximations. This is our craft moat over the existing community GUIs.

### 6.1 Foundations (the eight principles applied)
- **Purpose / restraint:** every screen answers one job. No dashboard-for-dashboard's-sake. Cut before adding.
- **Agency + forgiveness:** destructive ops (delete container/volume/`down --volumes`) get undo where possible (stopped ≠ deleted) and a confirmation **only** when truly irreversible (volume delete). Everything else is instant + undoable. Never trap: every detail view has obvious back/escape.
- **Familiarity:** standard macOS anatomy — `NavigationSplitView` sidebar, toolbar, inspector panel, ⌘F filtering, contextual menus, drag-and-drop (drop a folder → build; drop compose.yaml → open project). Close/traffic-lights, Settings in ⌘,, menu bar with full command coverage + keyboard shortcuts.
- **Direct, specific labels:** sidebar says "Containers, Images, Compose Projects, Volumes, Networks, Machines, System" — no "Home".
- **Grouping & mapping:** actions live on the row/entity they affect (row swipe/hover actions, inspector buttons), not in a distant global toolbar.
- **Feedback taxonomy:** status (live state dots, pull/build progress), completion (subtle checkmark pulse), warning (image about to be pruned is in use), error (inline, actionable, with the underlying `container` stderr one disclosure away — never a bare "failed").

### 6.2 Layout

```text
┌ Sidebar ────────────┬ Content ──────────────────────────┬ Inspector ─────────┐
│ ▸ Compose Projects  │ payments-api          ● Running   │ api                │
│    payments-api  ●  │ ┌──────────────────────────────┐  │ Image, IP, Ports   │
│    blog-stack    ○  │ │ ● api    Healthy  :8080→80   │  │ Env, Mounts        │
│ Containers          │ │ ● db     Healthy  pg:5432    │  │ [Logs][Term][Stats]│
│ Images              │ │ ● redis  Running             │  │ Health history     │
│ Volumes             │ └──────────────────────────────┘  │                    │
│ Networks            │ [Up][Down][Restart][Plan][Config] │                    │
│ Machines            │ Tabs: Logs │ Graph │ Resources    │                    │
│ System              │                                   │                    │
└─────────────────────┴───────────────────────────────────┴────────────────────┘
```

- Translucent sidebar (`.sidebar` material) — heavier material separates the structural region; content lists on plain background; **never stack light translucent surfaces**.
- Log/terminal views: solid dark background (translucency destroys terminal legibility), monospaced SF Mono, vibrancy-correct secondary text.
- Sticky headers over scrolling logs use a scroll-edge blur/gradient, not a 1px divider.

### 6.3 Motion (springs, interruptible, restrained)
- **House style: critically damped.** `.spring(response: 0.35, dampingFraction: 1.0)` for panel/inspector/sheet/selection transitions. No bounce on things that merely appear.
- **Bounce only follows momentum:** drag-to-reorder release, flick-dismiss of a sheet → `dampingFraction ~0.8, response ~0.3`.
- **Interruptibility:** all transitions driven by state + springs (SwiftUI re-targets from presentation value natively — this is the additive-animation behavior the skill demands). Never disable hit-testing during a transition; a closing inspector grabbed again follows the pointer.
- **Response first:** pressed states on pointer-down (`.buttonStyle` with instant scale 0.97 highlight); progress starts rendering the moment a pull/build begins (indeterminate → determinate handoff), no debounce on the input path.
- **Continuous feedback during gestures:** resizing inspector, scrubbing a stats timeline, dragging a service card in the graph — 1:1 tracking, grab-offset respected, rubber-band at bounds (never hard-stop).
- **Spatial consistency:** inspector slides in from the right, dismisses to the right; popovers scale from their trigger (`transform-origin` = source); enter/exit mirrored.
- **State-change choreography:** container state dot transitions (stopped→starting→running→healthy) animate color/scale with a single small spring pulse — causality obvious, no confetti.

### 6.4 Typography & density
- System fonts only (SF Pro / SF Mono), Dynamic Type text styles (`.largeTitle`→`.caption`), weight-first hierarchy.
- Large titles (project name) get tight leading + slight negative tracking; table/body text default tracking; dense tables use tabular numerals for ports/IPs/sizes.
- Spacing in scalable units; layout must survive larger accessibility text sizes.

### 6.5 Accessibility & modes
- `accessibilityReduceMotion` → cross-fades replace slides/springs; no scale pulses.
- `accessibilityReduceTransparency` → solid sidebar/toolbars.
- Increase-contrast → defined borders on materials.
- Full keyboard navigation; VoiceOver labels on state dots ("api — running, healthy, port 8080").
- Light/dark adaptive; ease theme transitions (no brightness snap).

### 6.6 Process (per the skill)
- **Prototype the feel first:** before M1 UI build-out, a 2–3 day interactive prototype of sidebar/list/inspector + one live-updating container row + terminal, reviewed frame-by-frame. The prototype sets the craft bar.
- Design interaction and visuals together — the state-dot spring, the log stream behavior, and the layout are one decision, not a "motion pass" later.

### 6.7 Brand & color — "Graphite & Indigo"

Foundation: Apple's own graphite neutrals — the app lives inside system materials anyway, so the neutrals must be indistinguishable from macOS itself. Brand: the **systemIndigo** family, a blue-violet that is literally one of Apple's accent colors, so it is guaranteed to sit well next to every system control — while staying clearly apart from Docker blue, Podman purple, and terminal green. Every token below is defined **per appearance mode**; the app resolves them via semantic `NSColor`/asset-catalog colors, never raw hex.

**Light mode**

| Token | Hex | Role |
|---|---|---|
| Background | `#F5F5F7` | Window/content background |
| Surface | `#FFFFFF` | Cards, list rows, inspector |
| Ink | `#1D1D1F` | Primary text |
| Secondary | `#6E6E73` | Secondary text, captions |
| Hairline | `#E5E5EA` | Separators, table rules |
| **Indigo (accent)** | `#5856D6` | Links, primary buttons, selection, focus — the brand |
| Indigo Tint | `#ECECFB` | Selected rows, badges, soft fills |

**Dark mode**

| Token | Hex | Role |
|---|---|---|
| Background | `#141416` | Window/content background |
| Surface | `#1D1D20` | Cards, list rows, inspector |
| Elevated | `#26262B` | Popovers, hovered rows, sheets |
| Text | `#F5F5F7` | Primary text |
| Secondary | `#98989D` | Secondary text, captions |
| Hairline | `#2C2C2E` | Separators, table rules |
| **Indigo (accent)** | `#5E5CE6` | Brighter dark-variant of the same accent |
| Indigo Tint | `rgba(94,92,230,.16)` | Selected rows, badges, soft fills |

**Always-dark surfaces (both modes):** terminal and log views sit on `#161618` with `#EBEBF0` text — logs never change color scheme under the user.

**Semantic state colors** — mapped to `NSColor.system*` so they adapt to appearance and increase-contrast automatically; reference hexes:

| State | Light | Dark | NSColor |
|---|---|---|---|
| Running / Healthy | `#34C759` | `#30D158` | systemGreen |
| Building / Starting | `#FF9500` | `#FF9F0A` | systemOrange |
| Unhealthy / Error | `#FF3B30` | `#FF453A` | systemRed |
| Stopped | `#8E8E93` | `#98989D` | systemGray |

**Usage rules**
1. **Accent never means state.** Indigo = interactive/brand; green/orange/red/gray = container state. An indigo "Running" dot is a bug.
2. Indigo is the app's *default* accent — if the user has set a system accent color, honor it (standard `AccentColor` asset behavior); the brand yields to the person.
3. Color lives on solid layers only. Materials/vibrancy get Indigo Tint as a selection wash (~14%), never a tinted translucent surface — per the vibrancy rules in §6.2.
4. Contrast: Indigo `#5856D6` on `#F5F5F7` is 5.5:1 (text-safe); `#5E5CE6` on `#141416` is 4.6:1 — both pass AA for UI text.
5. All neutrals come from semantic system colors in the app (`windowBackgroundColor`, `labelColor`, `separatorColor`, …); the hexes above are the documented reference values for docs, HTML, and the icon.

**App icon direction:** a two-tone capsule pill at ~30° — upper half solid Indigo, lower half graphite glass with a faint inner blur, a small bright core dot at the seam. Reads as a pill at 16px, as glass at 512px.

---

## 7. Testing strategy (brief)

- **ComposeSpec:** golden tests — fixture YAML → resolved JSON snapshots (incl. interpolation, .env precedence, error cases).
- **ComposePlanner:** golden plans — model + fake observed state → expected step DAG (pure, fast, hundreds of cases).
- **ComposeRuntime/Supervisor:** `FakeContainerRuntime` (protocol!) for orchestration logic incl. failure injection (pull fails, health flaps, container dies mid-up).
- **Integration (self-hosted Apple-silicon runner):** real `container` runtime, smoke matrix: nginx solo, postgres+api with `service_healthy`, named volume persistence across `down/up`, port publish reachability, DNS resolution per §4.4 decision.
- **UI:** ViewModel unit tests against FakeRuntime; a handful of XCUITest smoke flows.

---

## 8. First-week task list

1. Spike S1 (DNS/networks) — outcome decides §4.4.
2. Spikes S2–S5 in parallel where possible; write findings into `docs/spikes/`.
3. Scaffold monorepo (§2.1), `ContainerRuntime` protocol, `CLIProcessClient` with `list/inspect/logs` + JSON models, version gate.
4. Poller → EventBus → a bare SwiftUI containers list that live-updates. (The "it's alive" moment.)
5. Feel prototype (§6.6) alongside.
