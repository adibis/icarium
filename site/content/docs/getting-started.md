---
title: Getting started
weight: 2
---

## Prerequisites

- **Zig 0.17** (exact pin in `pins.json`; check with
  `sh scripts/check-pins.sh`).
- **Yosys 0.70** on `PATH` for elaborating SystemVerilog and for the
  end-to-end suite. Install with Homebrew: `brew install yosys`.
- Python 3 + `jsonschema` only for the schema-gated suites.

## Build

```sh
git clone https://github.com/adibis/icarium
cd icarium
zig build          # builds ./zig-out/bin/icarium
zig build test     # unit tests
```

`zig build e2e` runs the SystemVerilog end-to-end suite; it needs
yosys on `PATH` and skips cleanly without it.

## First check

With your own `design.sv` and a hand-written `spi.sdc` (see
[SDC subset]({{% relref "docs/sdc.md" %}}); examples under
`bench/sdc/`):

```sh
./zig-out/bin/icarium check --top spi_device --sdc spi.sdc design.sv
```

icarium first elaborates the sources into the flat netlist it
reads, by running Yosys (`read_verilog -sv`, `hierarchy -check`,
`proc`, `flatten`) with no optimization passes, so flops and
muxes stay visible. Pass include directories with `-I DIR` and
defines with `-D NAME=VALUE`; `--frontend slang` reads the
sources with yosys-slang instead.

Elaborating a large design takes a while. To check the same
netlist again, save it once and pass it with `--yosys-json`:

```sh
sh scripts/elaborate.sh --top spi_device --out spi.json design.sv
./zig-out/bin/icarium check --yosys-json spi.json --top spi_device \
    --sdc spi.sdc
```

Exit 0 means clean; exit 1 means error-severity findings (the report
still prints). Start with `--format ids` for a compact rule-per-line
view, or `--format json` for the machine-readable report.

## Large designs

Designs too big to materialize stream instead: `--stream` walks the
netlist in chunks and keeps only findings plus small accumulators.
The full EarlGrey top (178,656 sources) checks this way in about
an hour. See [CLI reference]({{% relref "docs/cli.md" %}}) for chunk
and pair-budget flags.

## Next steps

- [Guides]({{% relref "docs/guides/_index.md" %}}) — worked walkthroughs: first run, findings, constraints
- [CLI reference]({{% relref "docs/cli.md" %}}) — every command and flag
- [SDC subset]({{% relref "docs/sdc.md" %}}) — which constraints icarium reads
- [Rules]({{% relref "docs/rules/_index.md" %}}) — what each rule flags and how to fix it
