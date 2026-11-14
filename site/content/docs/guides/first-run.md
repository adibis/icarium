---
title: Your first CDC run
weight: 1
---

This guide assumes a built tree ([Getting
started]({{% relref "docs/getting-started.md" %}})). It runs one
buggy design end to end: elaborate, check, read, fix, green.
Work from the repo root, with Yosys on `PATH`:

```sh
cd "$(git rev-parse --show-toplevel)"
command -v yosys  # elaborate.sh exits 3 without it
```

## The design

Two flops, two clocks, one missing synchronizer
(`fixtures/CDC-001/bad_sync_missing.sv`):

```systemverilog
module bad_sync_missing (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic q
);
  logic src_q, dst_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) dst_q <= src_q;
  assign q = dst_q;
endmodule
```

`src_q` lives in `ca`; `dst_q` samples it in `cb`. There is
no second stage, so `dst_q` samples a foreign signal raw. The
constraints declare the two clocks and their relationship
(`fixtures/CDC-001/bad_sync_missing.sdc`):

```tcl
create_clock -name ca -period 10 [get_ports ca]
create_clock -name cb -period 7 [get_ports cb]
set_clock_groups -asynchronous -group {ca} -group {cb}
set_input_delay -clock ca 1.0 [get_ports d]
```

## Elaborate and check

```sh
sh scripts/elaborate.sh --top bad_sync_missing --out /tmp/guide.json \
    fixtures/CDC-001/bad_sync_missing.sv
```

Elaboration prints the Yosys transcript (trimmed here; the
tool prints all of it):

```text
 Yosys 0.70+post (git sha1 0c11ea098be065e585a90a06e7b7da49936cf231, Release, AppleClang clang++ 21.0.0.21000334)

-- Running command `read_verilog -sv  fixtures/CDC-001/bad_sync_missing.sv; hierarchy -check -top bad_sync_missing; proc; flatten; write_json /tmp/guide.json' --
[... frontend, hierarchy, and proc passes ...]
3.9. Executing PROC_DFF pass (convert process syncs to FFs).
Creating register for signal `\bad_sync_missing.\dst_q' using process `\bad_sync_missing.$proc$fixtures/CDC-001/bad_sync_missing.sv:10$2'.
  created $dff cell `$procdff$3' with positive edge clock.
Creating register for signal `\bad_sync_missing.\src_q' using process `\bad_sync_missing.$proc$fixtures/CDC-001/bad_sync_missing.sv:9$1'.
  created $dff cell `$procdff$4' with positive edge clock.
[... flatten, JSON backend ...]
End of script. Logfile hash: f8de42fd25, time: [varies run to run]
```

Note the two `$procdff` cells and their source lines — those
names appear in the finding next:

```sh
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc fixtures/CDC-001/bad_sync_missing.sdc
```

```text
CDC-001 [error] Unsynchronized control crossing (1 finding)
  $procdff$3 @ fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42 <- $procdff$4 @ fixtures/CDC-001/bad_sync_missing.sv:9.3-9.38: unsynchronized control crossing ca -> cb (src: flop $procdff$4): destination flop $procdff$3 has no second-stage synchronizer (chain depth = 1)
```

Exit code 1. The destination flop at line 10 takes its data
from the source flop at line 9, across `ca -> cb`, with
chain depth 1 — a synchronizer needs two. (See [Reading a
finding]({{% relref "docs/guides/reading-findings.md" %}})
for the full decode.)

## Fix the RTL — on a copy

Don't edit the fixture in place: the test suites read it. Copy it to scratch and edit the copy:

```sh
mkdir -p /tmp/cdc-run
cp fixtures/CDC-001/bad_sync_missing.sv /tmp/cdc-run/design.sv
```

Add the missing stage to `/tmp/cdc-run/design.sv`:

```systemverilog
  logic src_q, s1_q, s2_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) s1_q <= src_q;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
```

Re-elaborate the copy (the netlist changed, so this step is
not skippable) and re-check against the same SDC:

```sh
sh scripts/elaborate.sh --top bad_sync_missing --out /tmp/guide-ok.json \
    /tmp/cdc-run/design.sv >/dev/null
./zig-out/bin/icarium check --yosys-json /tmp/guide-ok.json \
    --top bad_sync_missing --sdc fixtures/CDC-001/bad_sync_missing.sdc
echo "exit=$?"
```

```text
exit=0
```

No output, exit 0. Silence is the verdict — every crossing
enumerated, every rule run, nothing to report.

Two warnings before you trust a green run. First, silence is
a verdict only over declared clocks: undeclared clocks and
untyped ports produce their own findings, and an undeclared
clock collapses its whole domain into one CDC-021. Break
the constraints on purpose in [Constraining clocks for
CDC]({{% relref "docs/guides/constraining-clocks.md" %}}) and
watch what each omission costs. Second, resist waiving an
error on first sight: an unsynchronized crossing is guilty
until the constraints prove otherwise. The usual story is a
missing synchronizer, not a wrong rule.
