---
title: Benchmarks
weight: 50
---


Three tiers of self-measurement, from hand fixtures to the full
chip. Machine: Apple M4 Pro arm64, 25.8 GB. Tools: icarium
Release, Yosys 0.70.

## Tier-1: 8 hand fixtures

Crossing, domain, reset, and clock snapshots over eight small
designs (gated, muxed, divided, and negedge clocks; sync and
async resets; memory and multi-clock cases). The e2e suite
replays every snapshot; each design checks in milliseconds.

## Tier-2: 5 OpenTitan blocks

Full rule checks with findings, timed release-fast:

| design | time | crossings | findings |
|---|---|---|---|
| uart | 0.58s | 344 | 46 |
| spi_device | 7.05s | 2,385,262 | 39,290 |
| gpio | 0.13s | 205 | 0 |
| alert_handler | 1.93s | 3,228 | 230 |
| lc_ctrl | 2.68s | 580,400 | 173 |

Cost tracks pairs, not netlist size: spi_device's wide bus
fanout dominates the tier.

## Tier-3: full EarlGrey top

The 983 MB flat top (178,656 sources) checks streamed in 65
minutes: 637,274 chunks, 1,977,807 findings across 18 rules,
peak RSS 14.8 GB. Peak memory follows one pair budget, never
the widest broadcast; declared divided and serial roots hold
unknown-domain flops to 63: 28 undriven analog and scan-gated
pins, 35 scan-muxed clocks whose undeclared scan legs the
union validator refuses. `--ignore-scan-mode` waives the
scan-clocked paths.

## Recall gate

Separately from scale tiers, OpenTitan's own Meridian
waivers replay as a recall gate: every waived entry gets a
verdict (full, partial, rule-only, missed). See
[Recall gate]({{% relref "docs/dev/recall.md" %}}).

For checker-vs-checker comparison, the standalone
[benchmark corpus]({{% relref "docs/benchmark-corpus/_index.md" %}})
measures any tool against ground truth instead of against
another tool's output.
