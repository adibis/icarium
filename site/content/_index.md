---
title: icarium
layout: hextra-home
---

<style>
  :root { --icarium-dark: #18181b; --icarium-amber: #df8e1d; }
  .icarium-hero {
    width: 100vw; position: relative; left: 50%;
    transform: translateX(-50%); margin-top: -2rem;
    background: var(--icarium-dark); color: #fff;
  }
  @media (min-width: 768px) { .icarium-hero { margin-top: -3rem; } }
  .hextra-footer > div:has(.hextra-theme-toggle) { display: none; }
  .hextra-footer > div:has(.hextra-theme-toggle) + hr { display: none; }
</style>

<div class="not-prose icarium-hero">
  <div style="max-width: 1400px; margin: 0 auto; padding: 3rem 3rem 2.75rem;">
    <span style="display: inline-flex; font: 600 0.6875rem var(--font-mono); color: #f2b84b; background: rgba(242, 184, 75, 0.14); border: 1px solid rgba(242, 184, 75, 0.35); padding: 0.3rem 0.6rem; border-radius: 20px; letter-spacing: 0.03em;">OPEN SOURCE &middot; APACHE-2.0</span>
    <h1 style="font: 700 clamp(2rem, 4.5vw, 3.125rem)/1.08 var(--font-sans); letter-spacing: -0.02em; margin: 1.25rem 0 0; max-width: 800px; color: #fff;">Structural CDC/RDC checking, fast enough for full-chip runs.</h1>
    <p style="font: 400 1.0625rem/1.55 var(--font-sans); color: #c4c4c4; max-width: 640px; margin: 1rem 0 0;">icarium checks clock-domain and reset-domain crossings in elaborated SystemVerilog. Zig-native, JSON-first, benchmarked against OpenTitan's own waivers — including the full EarlGrey top.</p>
    <div style="display: flex; gap: 0.9rem; margin-top: 1.6rem; align-items: center; flex-wrap: wrap;">
      <a href="docs/getting-started/" style="font: 600 0.875rem var(--font-sans); background: #df8e1d; color: #18181b; padding: 0.75rem 1.5rem; border-radius: 0.4rem; text-decoration: none;">Get started &rarr;</a>
      <a href="docs/rules/" style="font: 600 0.875rem var(--font-sans); color: #fff; border: 1px solid rgba(255, 255, 255, 0.3); padding: 0.7rem 1.4rem; border-radius: 0.4rem; text-decoration: none;">Browse the rules &rarr;</a>
    </div>
    <div style="margin-top: 1.75rem; max-width: 640px; background: #101012; border: 1px solid rgba(255,255,255,0.12); border-radius: 0.5rem; padding: 1rem 1.25rem; font: 400 0.8125rem/1.7 var(--font-mono); color: #e5e5e5;">
      <div><span style="color:#f2b84b;">$</span> zig build</div>
      <div><span style="color:#f2b84b;">$</span> sh scripts/elaborate.sh --top spi_device --out spi.json design.sv</div>
      <div><span style="color:#f2b84b;">$</span> ./zig-out/bin/icarium check --yosys-json spi.json --top spi_device --sdc spi.sdc</div>
    </div>
  </div>
</div>

## Why icarium

{{< hextra/feature-grid >}}
  {{< hextra/feature-card
    title="Full-chip scale"
    subtitle="Streams billion-pair designs without materializing them: the 983 MB EarlGrey flat top checks in 65 minutes at 15 GB peak RSS."
  >}}
  {{< hextra/feature-card
    title="JSON-native, spec-aligned"
    subtitle="Findings, waivers, baselines, and domain maps are versioned JSON schemas, with Accellera 1.0 Tcl interchange as an accessory."
  >}}
  {{< hextra/feature-card
    title="Waiver-benchmarked"
    subtitle="OpenTitan ships CDC/RDC waivers; icarium replays them as a recall gate, so every release proves it still catches what the waivers excuse."
  >}}
{{< /hextra/feature-grid >}}
