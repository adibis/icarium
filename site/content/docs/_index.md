---
linkTitle: "Documentation"
title: Introduction
weight: 1
---

icarium is an open-source structural CDC (clock-domain crossing) and RDC
(reset-domain crossing) checker written in Zig. It reads a Yosys JSON
netlist — Yosys, the open-source synthesizer, elaborates the
SystemVerilog first — plus an SDC constraints file, then traces
clocks and resets structurally, enumerates crossings, and runs
a rule set over them. New here? Work the
[Guides]({{% relref "docs/guides/_index.md" %}}).

## What it checks

- **CDC**: signals sampled across clock domains — missing
  synchronizers, shallow chains, logic around synchronizers,
  bus crossings, and clocks the constraints never declare.
  See [Rules]({{% relref "docs/rules/_index.md" %}}) for the
  full catalog.
- **RDC**: the same races in reset trees — async resets
  released from foreign clock domains, combinational or muxed
  reset sources, and reset-synchronizer chain integrity. These
  are reset-structure and reset-release checks: they ask how a
  reset is built and where it deasserts.

## What it is not

icarium is structural and static: it reasons about the elaborated
netlist, not simulation traces or formal proofs. It does not replace
timing signoff (final static-timing closure); it catches the
crossing bugs before signoff gets them.

It does not analyze reset assertion. An async reset that asserts
in one domain changes its flops asynchronously to any receiver that
keeps running: another reset domain, or storage with no reset. What
that receiver captures can be corrupt. Catching that needs reset
sequencing and receiver-side qualification that icarium does not
model; its RDC rules check structure and release only.

It does not compute MTBF. Rules that concern resolution time
(opposite-edge stages, gates inside a chain, chain depth) report the
shape; how much margin a design needs depends on the flop library,
clock rates and data rates, which the netlist does not carry.

## Assumptions

icarium assumes what the
[cdc-rdc-tests assumptions](https://github.com/adibis/cdc-rdc-tests/blob/master/docs/assumptions.md)
state for every checker. Clocks and their relations come only from
the SDC, and undeclared pairs are related. Resets are as the netlist
builds them. Unreset state is unknown and never relied on. Inputs may
change on any edge of the clock they are typed to; an untyped input
gets a typing finding rather than a guess. No rule assumes a traffic
rate beyond the declared clock periods.

## Pipeline

![icarium pipeline](/images/overview/pipeline.svg)

Start with [Getting started]({{% relref "docs/getting-started.md" %}}),
then work the [Guides]({{% relref "docs/guides/_index.md" %}}),
or jump to the [CLI reference]({{% relref "docs/cli.md" %}}), the
[rule catalog]({{% relref "docs/rules/_index.md" %}}), or
[how it is benchmarked]({{% relref "docs/benchmarks.md" %}}).
