---
title: Constraining clocks for CDC
weight: 3
---

The checker can only verify the clocks you declare. This
guide builds the SDC for the [first-run
design]({{% relref "docs/guides/first-run.md" %}}) line by
line, then breaks it three ways. Every output below is real,
run against the first-run netlist (`/tmp/guide.json`) — an
SDC-only change needs no re-elaboration, so each break is
one `cp`, one edit, one check. Work on copies, never on the
fixture:

```sh
mkdir -p /tmp/cdc-run
cp fixtures/CDC-001/bad_sync_missing.sdc /tmp/cdc-run/timing-nogroups.sdc
cp fixtures/CDC-001/bad_sync_missing.sdc /tmp/cdc-run/timing-notyping.sdc
cp fixtures/CDC-001/bad_sync_missing.sdc /tmp/cdc-run/timing-nocb.sdc
```

## Declare the clocks

```tcl
create_clock -name ca -period 10 [get_ports ca]
create_clock -name cb -period 7 [get_ports cb]
```

Each line names a clock, gives its period (any consistent
time unit — only the CDC-009/013 ratios consume it), and
roots it on an input port. Names are yours. A clock with no
`create_clock` is not a slow clock or a related clock — it
is unknown, and the checker says so with CDC-021 (see the
third break).

## Declare the relationship

```tcl
set_clock_groups -asynchronous -group {ca} -group {cb}
```

The two clocks never meet in time. Write it even though the
checker defaults ungrouped pairs to async (the first break
proves it): the grouping documents intent, and intent is
what the next reader audits.

## Type the boundary

```tcl
set_input_delay -clock ca 1.0 [get_ports d]
```

Input `d` arrives in `ca`'s domain. The delay value is
boundary context the checker does not consume; what matters
is the clock name. An untyped input carries no domain, and
CDC-011 will tell you (the second break).

The assembled file is the fixture SDC:

```tcl
create_clock -name ca -period 10 [get_ports ca]
create_clock -name cb -period 7 [get_ports cb]
set_clock_groups -asynchronous -group {ca} -group {cb}
set_input_delay -clock ca 1.0 [get_ports d]
```

## Break it: missing groups

Delete the `set_clock_groups` line from
`timing-nogroups.sdc` and check:

```sh
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc /tmp/cdc-run/timing-nogroups.sdc --format ids
```

```text
CDC-001
```

Identical verdict, exit 1. Doubt fires, it does not pass:
an ungrouped pair defaults to async, so the crossing still
reports. The grouping line buys documentation, not
detection — write it for the reader, not the tool.

## Break it: untyped input

Delete the `set_input_delay` line from
`timing-notyping.sdc` and check:

```sh
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc /tmp/cdc-run/timing-notyping.sdc --format ids
```

```text
CDC-001
CDC-011
```

CDC-001 still fires on the flop-to-flop crossing, and
CDC-011 joins it: the untyped port reaching clocked logic.
Two findings, two problems, each with its own fix — type
the port, then synchronize the crossing.

## Break it: undeclared clock

Delete the `cb` clock from `timing-nocb.sdc` and check in
full text:

```sh
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc /tmp/cdc-run/timing-nocb.sdc
```

The crossing now reads `ca -> port:cb`, and CDC-021 names
the missing declaration — including the exact line to add:

```text
CDC-001 [error] Unsynchronized control crossing (1 finding)
  $procdff$3 @ fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42 <- $procdff$4 @ fixtures/CDC-001/bad_sync_missing.sv:9.3-9.38: unsynchronized control crossing ca -> port:cb (src: flop $procdff$4): destination flop $procdff$3 has no second-stage synchronizer (chain depth = 1)
CDC-021 [error] Flop clock driven by an undeclared port (1 finding)
  $procdff$3 @ fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42: flop CLK driven by undeclared port: top-level input port 'cb' drives flop $procdff$3 but has no create_clock declaration in the SDC. All other CDC checks that touch this domain are silently skipped. Add `create_clock -name cb -period <T> [get_ports cb]` to the SDC.
```

(The tool prints each finding on one long line; wrapped
here for the page.)

Read that message as a checklist with teeth: every clock
declared, every input typed, every pair grouped. The
checker grades your constraints before it grades your RTL —
constrain completely, then argue with the findings that
remain.
