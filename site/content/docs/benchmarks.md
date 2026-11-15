---
title: Benchmarks
weight: 50
---

Three tiers of self-measurement, from hand fixtures to the full
chip. Machine: Apple M4 Pro arm64, 25.8 GB. Tools: icarium
Release, Yosys 0.70.

## Tier-1: 8 hand fixtures

Eight small designs covering gated, muxed, divided, and
negedge clocks, sync and async resets, and memory and
multi-clock cases. Each elaborates and checks in milliseconds;
each present output is diffed byte-for-byte (`cmp`) against
its golden: always stats, plus clocks, domains, resets, and
crossings where the case defines them. Any modeling change
shows up immediately.

## Tier-2: 5 OpenTitan blocks

Full rule checks on real blocks, timed with optimized
release builds.
Crossings counts source-to-sink bit pairs: wide buses
multiply it fast, which is why spi_device dominates the
tier while gpio barely registers.

| design | time | crossings | findings |
|---|---|---|---|
| uart | 0.58s | 344 | 46 |
| spi_device | 7.05s | 2,385,262 | 39,290 |
| gpio | 0.13s | 205 | 0 |
| alert_handler | 1.93s | 3,228 | 230 |
| lc_ctrl | 2.68s | 580,400 | 173 |

Check time tracks pairs, not netlist size.

## Tier-3: full EarlGrey top

The 983 MB flat top (178,656 sources) checks streamed in 65
minutes: 637,274 chunks, 1,977,807 findings across 18 rules,
peak RSS 14.8 GB. Streaming caps memory at one pair budget
instead of the widest broadcast (see
[Streaming]({{% relref "docs/dev/streaming.md" %}})). 63 flops
stay unknown (unassignable to any declared clock): 28 undriven
analog and scan-gated pins, plus 35 scan-muxed clocks whose
undeclared scan legs fail validation. `--ignore-scan-mode`
waives the scan-clocked paths.

## Recall gate

Separately from scale tiers, OpenTitan's Meridian waivers
(Tcl `set_rule_status` files, converted by
[`import-meridian`]({{% relref "docs/formats.md" %}}))
replay as a recall gate over 465 in-scope entries. An entry is
found when a finding lands on both of its endpoints (full) or
one (partial):

| design | entries | full | partial | rule only | missed |
| ------ | ------: | ---: | ------: | --------: | -----: |
| 5 blocks | 21 | 9 | 10 | 2 | 0 |
| EarlGrey top | 444 | 49 | 220 | 174 | 0 |

"Rule only" means the mapped rule fired in the design but on
neither endpoint; it is a diagnostic, not a match. One top
entry is a known modeling gap. See
[Recall gate]({{% relref "docs/dev/recall.md" %}}).

## Test suite

[cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests) is a
separate, tool-neutral suite: 206 small designs, each with the
exact findings a correct checker reports, including the
designs where it must report nothing. Any CDC/RDC checker can
run it. Every case also compiles in Verilator, Xezim and slang
and synthesizes cleanly in Yosys, so a failure is about the
crossing, never the SystemVerilog.
icarium passes all 206.
