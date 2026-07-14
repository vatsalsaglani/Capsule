# Native containers, without the desktop tax

<section class="capsule-hero">
  <div class="capsule-hero__copy">
    <span class="capsule-kicker">CAPSULE · macOS 26</span>
    <h1>Compose projects.<br><span>Mac-native control.</span></h1>
    <p>Capsule is a SwiftUI container manager and Compose-style orchestrator for Apple’s <code>container</code> runtime. The app and CLI share one tested engine.</p>
    <div class="capsule-hero__actions">
      <a class="md-button md-button--primary" href="getting-started/">Get started</a>
      <a class="md-button capsule-button--quiet" href="CLI/">Read the CLI reference</a>
    </div>
  </div>
  <div class="capsule-hero__mark" aria-label="Capsule app icon">
    <img src="assets/capsule-icon.png" alt="">
    <span>One engine</span>
    <code>Capsule.app + capsule</code>
  </div>
</section>

<div class="capsule-signal-row">
  <span><i class="signal signal--green"></i> Container lifecycle</span>
  <span><i class="signal signal--orange"></i> Streamed builds</span>
  <span><i class="signal signal--indigo"></i> Plan before apply</span>
</div>

## The whole local stack, in one native surface

<div class="capsule-feature-grid" markdown>
<article class="capsule-feature capsule-feature--wide" markdown>
### Compose, made legible

Import a Compose file, inspect its dependency graph, review the exact plan, then bring services up with bounded progress and honest unsupported-key reporting.

```console
$ capsule compose plan
network  ─┬─ mysql ── mysql-ui
          └─ redis ── redis-ui
$ capsule compose up -d
```
</article>

<article class="capsule-feature" markdown>
### Native runtime manager

Containers, images, volumes, networks, builds, and persistent machines use adaptive card and table views—with actions attached to the resource they affect.
</article>

<article class="capsule-feature" markdown>
### Logs you can trust

Solid, readable consoles; bounded UI buffers; durable project spools; cancellable pull and build streams.
</article>

<article class="capsule-feature" markdown>
### One engine, two frontends

CapsuleKit owns every operation. SwiftUI and `capsule` remain thin, consistent frontends over the same runtime contracts.
</article>

<article class="capsule-feature capsule-feature--accent" markdown>
### Honest Compose scope

Capsule supports a documented subset. Every unimplemented key is a warning or a fatal finding—never silently ignored.
</article>
</div>

## Start with the CLI

```sh
swift build
swift test
swift run capsule doctor
swift run capsule compose plan -f Fixtures/compose/basic-web-db.yaml
```

[Build the app or install a release →](getting-started.md){ .capsule-inline-link }

!!! note "Developer preview"
    Current GitHub releases are ad-hoc signed and not notarized. Capsule publishes checksums and documents the one-time quarantine command on every release. Only run artifacts you trust.
