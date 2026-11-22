# Release notes

## v0.2.0

- **Findings name your RTL.** Every report shows the register or net a flop came from
  (`dst_q`, `u_a.q_reg`, `bus[5:4]`) instead of the Yosys cell (`$procdff$3`), in the
  endpoint and in the message. JSON and TOON keep the netlist name beside it: findings
  schema 1.1 adds `signal` to each endpoint, and `name` is unchanged.
- **Waivers may name signals.** A `dst` or `driver` pattern matches the RTL signal or the
  netlist name, so waivers written from a report work, and existing ones keep matching.
- **Baselines** match the messages reports now print, and still accept a 0.1 baseline.
- **Instance paths** drop Yosys's `$flatten\` and `\` spellings (`u_mid/u_leaf`, not
  `$flatten\u_mid/\u_leaf`), and a gate's generated name no longer splits on the dot in
  its source path.
- **CDC-018** states its contract: it warns at depth >= threshold (default 4), as it
  always did, and its message names the threshold.

## v0.1.0

First public release: a structural CDC/RDC checker for elaborated SystemVerilog.

- **36 rules:** CDC-001 to CDC-026 (CDC-007 reserved) and RDC-001 to RDC-011, each with
  failing and passing fixtures. `icarium rules` lists them.
- **Binaries** for Linux and macOS (x86_64, arm64), with `elaborate.sh` beside
  `icarium` in `bin/`.
- **Input:** a Yosys JSON netlist from `scripts/elaborate.sh` (stock `read_verilog -sv` or
  the slang front end) plus an SDC subset: clocks, generated clocks, asynchronous clock
  groups, and port typing with `set_input_delay`/`set_output_delay`.
- **Output:** text, JSON, SARIF and TOON reports, plus clock and reset maps. Exit status 1
  when error-severity findings remain.
- **Suppressions:** waiver files, source attributes and pragmas; `import-meridian` converts
  Meridian `set_rule_status` waivers.
- **Full-chip mode:** `--stream` checks designs too large to hold at once. OpenTitan's full
  EarlGrey top checks in about an hour.
- **Measured against OpenTitan's own waivers:** every waived violation in five OpenTitan
  blocks gets a verdict, with none missed; see the Benchmarks page for endpoint recall.

Known limitations, planned for the next releases:

- Findings name Yosys cells (`$procdff$3`) rather than your RTL signals.
- Each bit of a bus is its own crossing, so wide buses produce many findings.
- Elaboration and checking are two commands.
