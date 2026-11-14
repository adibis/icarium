# icarium

[![ci](https://github.com/adibis/icarium/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/adibis/icarium/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/adibis/icarium)](https://github.com/adibis/icarium/releases)
[![docs](https://img.shields.io/badge/docs-adibis.github.io%2Ficarium-blue)](https://adibis.github.io/icarium/)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

icarium is an open-source structural checker for clock-domain crossings (CDC)
and reset-domain crossings (RDC) in SystemVerilog designs. It reads the netlist
Yosys elaborates from your RTL, plus your SDC clock constraints, and reports
crossings that can go metastable or release out of order.

- **36 rules**: unsynchronized and shallow synchronizers, logic before a
  synchronizer, reconvergence, unsafe buses, async mux selects, foreign
  reset releases, reset polarity and ordering, and more.
- **Full-chip scale**: a streaming mode checks OpenTitan's full EarlGrey top.
- **Reports for people and tools**: text, JSON, SARIF (for code-scanning
  UIs) and TOON, with clock and reset domain maps.
- **Waivers that move with you**: waiver files, RTL attributes and pragmas;
  `import-meridian` converts existing Meridian waivers.
- **A single binary**: written in Zig, with no runtime dependencies beyond
  Yosys for elaboration.

## What a finding looks like

```systemverilog
always_ff @(posedge ca) src_q <= d;       // line 9
always_ff @(posedge cb) dst_q <= src_q;   // line 10: ca and cb are asynchronous
```

```text
CDC-001 [error] Unsynchronized control crossing (1 finding)
  $procdff$3 @ bad_sync_missing.sv:10.3-10.42 <- $procdff$4 @ bad_sync_missing.sv:9.3-9.38:
  unsynchronized control crossing ca -> cb (src: flop $procdff$4): destination flop
  $procdff$3 has no second-stage synchronizer (chain depth = 1)
```

## Install

Download a release for Linux or macOS (x86_64 or arm64) from
[Releases](https://github.com/adibis/icarium/releases). Each tarball has
`bin/icarium` and `bin/elaborate.sh`. You also need
[Yosys](https://github.com/YosysHQ/yosys) on `PATH` (tested with 0.70).

To build from source, install [Zig](https://ziglang.org/) 0.17.1
(pinned in `pins.json`), then:

```sh
zig build                 # ./zig-out/bin/icarium
zig build test            # unit tests
```

## Check a design

```sh
elaborate.sh --top my_top --out my_top.json rtl/*.sv
icarium check --yosys-json my_top.json --top my_top --sdc my_top.sdc
```

`icarium check` exits 1 when error-severity findings remain, so it can gate CI.
See [Getting started](https://adibis.github.io/icarium/docs/getting-started/)
and the [rule reference](https://adibis.github.io/icarium/docs/rules/).

## How it is measured

No commercial CDC tool is used as a reference. icarium is scored against two
open ground truths:

- **OpenTitan's own waivers.** Every CDC violation OpenTitan's designers
  reviewed and waived is a crossing a checker must report. On the full
  EarlGrey top, icarium's findings land on one or both waived endpoints for
  269 of 444; for 174 more, the expected rule fires elsewhere in the design,
  and none is missed outright. See
  [Benchmarks](https://adibis.github.io/icarium/docs/benchmarks/).
- **[cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests)**, a tool-neutral
  suite of 206 small designs with exact expected verdicts. icarium passes all
  206.

## Status

icarium is young. Known limitations, all on the roadmap:

- Findings name Yosys cells (`$procdff$3`) rather than RTL signals.
- Each bit of a bus is reported as its own crossing.
- Elaboration and checking are two commands.

Release notes are in [NOTES.md](NOTES.md).

## Contributing

Bug reports with a small failing design are the most useful contribution. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to report a bug, send a patch, and
certify your contribution. Security issues: see [SECURITY.md](SECURITY.md).

## Citing

If you use icarium in published work, cite it with the metadata in
[CITATION.cff](CITATION.cff).

## License

Copyright 2026 Aditya Shevade and the [icarium contributors](CONTRIBUTORS).
Licensed under the [Apache License 2.0](LICENSE).
