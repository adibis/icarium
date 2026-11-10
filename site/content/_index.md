---
title: icarium
layout: hextra-home
---

<div class="not-prose icarium-hero">
  <span class="icarium-badge">OPEN SOURCE &middot; APACHE-2.0</span>
  <h1>Structural CDC/RDC checking, fast enough for full-chip runs.</h1>
  <p>icarium checks clock-domain and reset-domain crossings in elaborated SystemVerilog. Zig-native, JSON-first, benchmarked against OpenTitan's own waivers — including the full EarlGrey top.</p>
  <div class="icarium-cta">
    <a class="icarium-cta-primary" href="docs/getting-started/">Get started &rarr;</a>
    <a class="icarium-cta-ghost" href="docs/rules/">Browse the rules &rarr;</a>
  </div>
  <div class="icarium-term">
    <div><span class="p">$</span> zig build</div>
    <div><span class="p">$</span> sh scripts/elaborate.sh --top spi_device \</div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;--out spi.json design.sv</div>
    <div><span class="p">$</span> ./zig-out/bin/icarium check --yosys-json spi.json \</div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;--top spi_device --sdc spi.sdc</div>
  </div>
</div>

## How it runs

![icarium pipeline](/images/overview/pipeline.svg)

## Benchmarks at a glance

| tier | scope | result |
| ---- | ----- | ------ |
| 1 | 8 hand fixtures | snapshots green, ms each |
| 2 | 5 OpenTitan blocks | 39,739 findings, slowest 7s |
| 3 | full EarlGrey top | 65 min streamed, 14.8 GB peak |
| recall | OpenTitan waivers | 465 entries, 0 missed |
