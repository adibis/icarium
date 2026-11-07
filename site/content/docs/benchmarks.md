---
title: Benchmarks
weight: 50
---

# Benchmarks

Three tiers, one honest rule: the reference reports few
crossings, so the differential gate is *misses* (reference
pairs we fail to cover), never counts. Full rows, machine
provenance, and per-run commits live in `bench/REPORT.md`;
this page summarizes.

Machine: Apple M4 Pro arm64, 25.8 GB. Tools: icarium
Release, rtl-buddy-cdc 0.7.3, Yosys 0.70.

## Tier-1: 8 hand fixtures

19/19 reference pairs covered, 0 missed. Both tools sit near
startup floor (~11 ms vs ~121 ms); no conclusion beyond parity.

## Tier-2: 5 OpenTitan blocks

17/17 reference pairs covered, 0 missed on every design.

| design | ours | ref | ours xings | ref xings | findings |
|---|---|---|---|---|---|
| uart | 0.31s | 0.21s | 207 | 0 | 0 |
| spi_device | 7.97s | 1.27s | 2,385,262 | 10 | 39,290 |
| gpio | 0.14s | 0.35s | 205 | 0 | 0 |
| alert_handler | 2.13s | 3.02s | 3,228 | 2 | 230 |
| lc_ctrl | 1.95s | 0.87s | 48,990 | 5 | 95 |

Speed is mixed and explained: cost tracks pairs, not netlist
size. Granularity differs by design — bit-level transitive
crossings versus hop-capped grouped ones — so counts are not
comparable across tools.

## Tier-3: full EarlGrey top

The 983 MB flat top (178,656 sources) checks streamed in 65
minutes: 637,274 chunks, 1,977,807 findings across 18 rules,
peak RSS 14.8 GB. Peak memory follows one pair budget, never
the widest broadcast; declared divided and serial roots hold
unknown-domain flops to 63, mostly tie-offs and DFT muxing.

## Recall gate

Separately from differentials, OpenTitan's own Meridian
waivers replay as a recall gate: every waived entry gets a
verdict (full, partial, rule-only, missed). See
[Recall gate]({{% relref "docs/dev/recall.md" %}}).
