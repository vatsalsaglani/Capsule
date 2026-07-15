---
title: Capsule
hide:
  - navigation
  - toc
---

<div class="capsule-home">
  <section class="capsule-hero" aria-labelledby="capsule-home-title">
    <div class="capsule-hero__copy">
      <div class="capsule-eyebrow">
        <span class="capsule-eyebrow__pulse" aria-hidden="true"></span>
        Developer preview · macOS 26
      </div>
      <h1 id="capsule-home-title">Your local stack,<br><span>Mac-native.</span></h1>
      <p class="capsule-hero__lede">Capsule gives Apple’s <code>container</code> runtime the workspace it deserves: Compose projects, containers, images, builds, volumes, and networks in one native app—with the same engine available from the CLI.</p>
      <div class="capsule-hero__actions">
        <a class="md-button md-button--primary" href="getting-started/">Get started</a>
        <a class="md-button capsule-button--secondary" href="https://github.com/vatsalsaglani/Capsule/releases">Download latest beta <span aria-hidden="true">↗</span></a>
      </div>
      <ul class="capsule-hero__facts" aria-label="Capsule highlights">
        <li><span aria-hidden="true">◆</span> Native SwiftUI</li>
        <li><span aria-hidden="true">◆</span> Shared CapsuleKit engine</li>
        <li><span aria-hidden="true">◆</span> Honest Compose subset</li>
      </ul>
    </div>

    <div class="capsule-workspace" aria-label="Capsule project workspace preview">
      <div class="capsule-workspace__titlebar">
        <div class="capsule-traffic-lights" aria-hidden="true"><i></i><i></i><i></i></div>
        <span>local-dev</span>
        <div class="capsule-runtime-state"><i aria-hidden="true"></i> Runtime ready</div>
      </div>
      <div class="capsule-workspace__body">
        <div class="capsule-workspace__rail">
          <div class="capsule-rail-brand"><img src="assets/capsule-icon.png" alt=""><span>Capsule</span></div>
          <div class="capsule-rail-item capsule-rail-item--active"><span>▱</span> Compose</div>
          <div class="capsule-rail-item"><span>◇</span> Containers</div>
          <div class="capsule-rail-item"><span>◉</span> Images</div>
          <div class="capsule-rail-item"><span>⌁</span> Networks</div>
        </div>
        <div class="capsule-workspace__main">
          <div class="capsule-project-head">
            <div><small>COMPOSE PROJECT</small><strong>local-dev</strong></div>
            <span class="capsule-count"><i aria-hidden="true"></i> 4 running</span>
          </div>
          <div class="capsule-service-list">
            <div class="capsule-service-row"><i class="capsule-state capsule-state--green"></i><span><strong>mysql</strong><small>mysql:8.4</small></span><code>3306</code><b>running</b></div>
            <div class="capsule-service-row"><i class="capsule-state capsule-state--green"></i><span><strong>redis</strong><small>redis:7.4-alpine</small></span><code>6379</code><b>running</b></div>
            <div class="capsule-service-row"><i class="capsule-state capsule-state--green"></i><span><strong>localstack</strong><small>localstack:3.8.1</small></span><code>4566</code><b>running</b></div>
            <div class="capsule-service-row"><i class="capsule-state capsule-state--orange"></i><span><strong>adminer</strong><small>adminer:latest</small></span><code>8088</code><b>starting</b></div>
          </div>
          <div class="capsule-terminal" aria-label="Compose command output">
            <div><span>$</span> capsule compose up -d</div>
            <p><i>◎</i> network local-dev_default&nbsp;&nbsp; <b>ready</b></p>
            <p><i>▰</i> volume local-dev_mysql-data&nbsp;&nbsp; <b>ready</b></p>
            <p><i>✓</i> 4 services started in 2.8s</p>
          </div>
        </div>
      </div>
    </div>
  </section>

  <section class="capsule-value" aria-labelledby="capsule-value-title">
    <div class="capsule-section-heading">
      <span class="capsule-section-index">01 / WHY CAPSULE</span>
      <h2 id="capsule-value-title">Container work without the desktop tax.</h2>
      <p>A focused control surface for the runtime already built into your development workflow.</p>
    </div>
    <div class="capsule-feature-grid">
      <article class="capsule-feature">
        <span class="capsule-feature__icon" aria-hidden="true">⌘</span>
        <h3>Compose you can inspect</h3>
        <p>Import a file, review its resolved configuration and dependency plan, then apply it with bounded, service-aware progress.</p>
        <a href="CLI/#capsule-compose-plan">Plan before apply <span aria-hidden="true">→</span></a>
      </article>
      <article class="capsule-feature">
        <span class="capsule-feature__icon" aria-hidden="true">◫</span>
        <h3>Runtime state, made legible</h3>
        <p>See lifecycle state, logs, resource usage, mounts, ports, and project ownership without translating raw runtime output.</p>
        <a href="getting-started/">Explore the app <span aria-hidden="true">→</span></a>
      </article>
      <article class="capsule-feature">
        <span class="capsule-feature__icon" aria-hidden="true">↔</span>
        <h3>One engine. Two frontends.</h3>
        <p>The SwiftUI app and <code>capsule</code> CLI are thin surfaces over CapsuleKit, so commands and UI actions stay consistent.</p>
        <a href="CLI/">Read the CLI reference <span aria-hidden="true">→</span></a>
      </article>
    </div>
  </section>

  <section class="capsule-command-panel" aria-labelledby="capsule-command-title">
    <div class="capsule-command-panel__copy">
      <span class="capsule-section-index">02 / START SMALL</span>
      <h2 id="capsule-command-title">Understand the plan.<br>Then bring it up.</h2>
      <p>Capsule reports every unsupported Compose key instead of quietly dropping configuration.</p>
      <a class="capsule-text-link" href="getting-started/">Install and run your first project <span aria-hidden="true">→</span></a>
    </div>
    <div class="capsule-command-panel__terminal">
      <div class="capsule-terminal-label"><span>compose.yaml</span><span>zsh</span></div>
      <pre><code><span class="term-dim">$</span> capsule compose config --report
<span class="term-good">✓</span> 5 services · 4 volumes · 1 network

<span class="term-dim">$</span> capsule compose plan
<span class="term-accent">◎</span> network  ─┬─ mysql ── adminer
           ├─ redis ── redisinsight
           └─ localstack

<span class="term-dim">$</span> capsule compose up -d
<span class="term-good">✓</span> project local-dev is running</code></pre>
    </div>
  </section>

  <section class="capsule-final-cta" aria-label="Get Capsule">
    <img src="assets/capsule-icon.png" alt="Capsule">
    <div><span class="capsule-section-index">CAPSULE 0.1 BETA</span><h2>Ready for your local stack.</h2></div>
    <a class="md-button md-button--primary" href="https://github.com/vatsalsaglani/Capsule/releases/tag/v0.1.3-beta">View the release <span aria-hidden="true">↗</span></a>
  </section>
</div>
