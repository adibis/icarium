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
    <div><span class="p">$</span> ./zig-out/bin/icarium check --top spi_device \</div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;--sdc spi.sdc design.sv</div>
  </div>
</div>

## What a finding looks like

A flop in clock `cb` samples a flop in clock `ca`, and the SDC declares the two clocks
asynchronous:

```systemverilog {filename="bad_sync_missing.sv",linenos=table,linenostart=9}
always_ff @(posedge ca) src_q <= d;
always_ff @(posedge cb) dst_q <= src_q;
```

```text
$ icarium check --yosys-json design.json --top bad_sync_missing --sdc clocks.sdc
CDC-001 [error] Unsynchronized control crossing (1 finding)
  dst_q @ bad_sync_missing.sv:10.3-10.42 <- src_q @ bad_sync_missing.sv:9.3-9.38:
  unsynchronized control crossing ca -> cb (src: flop src_q): destination flop
  dst_q has no second-stage synchronizer (chain depth = 1)
```

The names are the registers your RTL declares, and the source locations point at the two
`always_ff` lines that assign them.

## How it runs

![icarium pipeline](/images/overview/pipeline.svg)

## Benchmarks

OpenTitan's repository carries Meridian waivers: CDC violations its designers reviewed
and signed off as safe. Each one is a crossing a checker should report, so icarium is
scored against them. A waived violation counts as found only when a finding lands on one
or both of its endpoints.

| design | waived violations | both endpoints | one endpoint | rule only | missed | icarium findings |
| ------ | ----------------: | -------------: | -----------: | --------: | -----: | ---------------: |
| 5 OpenTitan blocks | 21 | 9 | 10 | 2 | 0 | 39,739 |
| full EarlGrey top | 444 | 49 | 220 | 174 | 0 | 1,977,807 |

"Rule only" means the expected rule fired in that design, but not on the waived signals; the one remaining top entry is a known modeling gap.
The finding counts are high because each bit of a bus is reported on its own; grouping
by signal is in progress. Full method and per-block numbers are on the
[benchmarks page]({{% relref "docs/benchmarks.md" %}}).
