---
linkTitle: "Documentation"
title: Introduction
weight: 1
---

icarium is an open-source structural CDC (clock-domain crossing) and RDC
(reset-domain crossing) checker written in Zig. It reads an elaborated
Yosys JSON netlist plus an SDC constraints file, traces clocks and resets
structurally, enumerates crossings, and runs a rule set over them.

## What it checks

- **CDC**: unsynchronized control crossings, synchronizer depth and
  placement, combinational logic around synchronizers, bus crossings
  (gray/gating), muxed and generated clocks, and unresolved clock
  association. See [Rules](/docs/rules/) for the full catalog.
- **RDC**: async resets driven from foreign domains, combinational or
  muxed reset sources, and reset-synchronizer chain integrity.

## What it is not

icarium is structural and static: it reasons about the elaborated
netlist, not simulation traces or formal proofs. It does not replace
timing signoff; it catches the crossing bugs before signoff gets them.

## Pipeline

```text
SystemVerilog → yosys → netlist.json ─┐
                                       ├─→ clock/reset trace → crossings → rules → findings
constraints.sdc ──────────────────────┘
```

Start with [Getting started]({{% relref "docs/getting-started.md" %}}),
or jump to the [CLI reference]({{% relref "docs/cli.md" %}}), the
[rule catalog]({{% relref "docs/rules/_index.md" %}}), or
[how it is benchmarked]({{% relref "docs/benchmarks.md" %}}).
