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
a rule set over them. New here? Start with
[Concepts]({{% relref "docs/concepts.md" %}}).

## What it checks

- **CDC**: signals sampled across clock domains — missing
  synchronizers, shallow chains, logic around synchronizers,
  bus crossings, and clocks the constraints never declare.
  See [Concepts]({{% relref "docs/concepts.md" %}}) for the
  vocabulary, [Rules]({{% relref "docs/rules/_index.md" %}})
  for the full catalog.
- **RDC**: the same races in reset trees — async resets
  released from foreign clock domains, combinational or muxed
  reset sources, and reset-synchronizer chain integrity. See
  [Concepts]({{% relref "docs/concepts.md" %}}) for reset domains.

## What it is not

icarium is structural and static: it reasons about the elaborated
netlist, not simulation traces or formal proofs. It does not replace
timing signoff (final static-timing closure); it catches the
crossing bugs before signoff gets them.

## Pipeline

![icarium pipeline](/images/overview/pipeline.svg)

Start with [Getting started]({{% relref "docs/getting-started.md" %}}),
or jump to the [CLI reference]({{% relref "docs/cli.md" %}}), the
[rule catalog]({{% relref "docs/rules/_index.md" %}}), or
[how it is benchmarked]({{% relref "docs/benchmarks.md" %}}).
