---
title: Reading a finding
weight: 2
---

Take the finding from [Your first CDC
run]({{% relref "docs/guides/first-run.md" %}}):

```text
CDC-001 [error] Unsynchronized control crossing (1 finding)
  dst_q @ fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42 <- src_q @ fixtures/CDC-001/bad_sync_missing.sv:9.3-9.38: unsynchronized control crossing ca -> cb (src: flop src_q): destination flop dst_q has no second-stage synchronizer (chain depth = 1)
```

## Anatomy

The header names the rule (`CDC-001`), its severity
(`error`), its title, and how many findings share the group.
The indented line pins the destination first (`dst_q @
...sv:10.3-10.42`), then `<-`, then the source behind it.
The message states the shape (`ca -> cb`, chain depth 1)
and the fix direction (add the second stage).

The names are your RTL's: `dst_q` is the register the
`always_ff` on line 10 assigns, with a bit range when a flop
covers part of a bus (`bus[5:4]`). The `@ file:line:col-col`
suffix points at that statement: `10.3-10.42` means line 10,
columns 3 to 42. Destination comes first because that is
where you start reading: the capture flop, then what feeds
it. A cell with no RTL name of its own, which is rare, keeps
the netlist name Yosys gave it.

## Grouped findings pin one end

Some rules cover several endpoints with one finding. This
CDC-019 ([cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests) case `fx_cdc019_bad_onehot_decode`) names
four source flops but pins the first:

```text
CDC-019 [warning] Independently-synced one-hot decode across CDC (1 finding)
  d0 @ cases/tier1/fx_cdc019_bad_onehot_decode/design.sv:18.5-23.8: independently-synced one-hot decode across CDC: comb cell one_hot drives 4 separate WIDTH=1 source flops (d0, d1, d2, d3) that each cross independently to clock domain dst_clk. The shared driver makes the lanes change together at the source, but each destination sync chain resolves on its own schedule. Fix: gray-code the source or gate the destination sample behind a req/ack handshake.
```

Read the pinned line first, then the message's list. Which
endpoint a rule pins — destination, source, chain head, or
group representative — is fixed per rule; when a pinned line
surprises you, the rule's [catalog
page]({{% relref "docs/rules/_index.md" %}}) describes the
shape it frames.

## Severity is a work order

**Error** is a probable bug. Fix the RTL, or record a
waiver with an expiry date explaining why the structure is
safe anyway.

**Warning** is a question with two answers. Take CDC-024,
one source fanning to two synchronizers (test-suite case
`cdc024_fanout_pair`, elaborated and checked the same way):

```text
CDC-024 [warning] Single source fanning to multiple synchronizers (1 finding)
  a @ cases/tier1/cdc024_fanout_pair/design.sv:16.5-16.36: fanout to 2 synchronizers: source a reaches independent sync chains in domain cb (chain heads: b1, a1); each chain resolves metastability on its own edge, so confirm the destinations never recombine the separately-resolved values
```

Outcome one: the destinations stay independent — no shared
downstream logic — and the warning waives with that reason.
Outcome two: they recombine, and the checker proves it with
a second warning on the same source. The test-suite case
`cdc005_reconvergent_pair` is that design — elaborate and
check it the same way (top `cdc005_reconvergent_pair`, its
`design.sdc`, `--format ids`):

```text
CDC-005
CDC-024
```

That pair is the verdict: CDC-005 proves the recombination,
so the skew is real and the fix is to synchronize once and
fan out after. The evidence that settles a warning is always
in the design, never in the finding alone — follow the
endpoints.

**Note** records a structure worth reviewing: a recognized
synchronizer, a multiclock report. Read it once; it never
fails a run by itself.

Exit codes follow severity, and only error moves them: 0 is
clean, warnings-only, or notes-only; 1 means error-severity
findings are present; 2 is bad arguments; 3 is an I/O or
internal error. Gate a pipeline on the exit code and triage
warnings on their own cadence.

## One check, every format

Run the first-run netlist once per format to see what each
is for:

```sh
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc fixtures/CDC-001/bad_sync_missing.sdc \
    --format ids
./zig-out/bin/icarium check --yosys-json /tmp/guide.json \
    --top bad_sync_missing --sdc fixtures/CDC-001/bad_sync_missing.sdc \
    --format json
```

`ids` collapses the finding to a single line for diffing:

```text
CDC-001
```

`json` emits the full versioned record — endpoints,
positions, message, waiver slot. Each endpoint carries both
names: `signal` is the RTL name the text shows, and `name` is
the netlist key that waivers and baselines also accept:

```json
{
  "schema_version": "1.1",
  "design": {
    "top": "bad_sync_missing"
  },
  "summary": {
    "errors": 1,
    "warnings": 0,
    "notes": 0,
    "carried_over": 0
  },
  "groups": [
    {
      "rule": "CDC-001",
      "severity": "error",
      "title": "Unsynchronized control crossing",
      "items": [
        {
          "severity": "error",
          "dst": {
            "name": "$procdff$3",
            "signal": "dst_q",
            "kind": "cell",
            "instance": "",
            "src": "fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42"
          },
          "driver": {
            "name": "$procdff$4",
            "signal": "src_q",
            "kind": "cell",
            "instance": "",
            "src": "fixtures/CDC-001/bad_sync_missing.sv:9.3-9.38"
          },
          "message": "unsynchronized control crossing ca -> cb (src: flop src_q): destination flop dst_q has no second-stage synchronizer (chain depth = 1)",
          "waiver": null
        }
      ]
    }
  ],
  "unmatched_waivers": []
}
```

The remaining two serve narrower readers. `sarif` feeds
code-scanning dashboards (533 lines for this one finding;
schema header, then one result per finding):

```json
{
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "icarium",
          "version": "0.2.0",
[... 524 more lines: rule metadata, then the finding as a result ...]
```

`toon` renders the same record as compact tables for LLM
pipelines:

```text
[1|]{rule|severity|title|dst|dst_signal|dst_kind|dst_instance|dst_src|driver|driver_signal|driver_kind|driver_instance|driver_src|message|waiver_id|waiver_reason|waiver_location}:
  CDC-001|error|Unsynchronized control crossing|$procdff$3|dst_q|cell|""|"fixtures/CDC-001/bad_sync_missing.sv:10.3-10.42"|$procdff$4|src_q|cell|""|"fixtures/CDC-001/bad_sync_missing.sv:9.3-9.38"|"unsynchronized control crossing ca -> cb (src: flop src_q): destination flop dst_q has no second-stage synchronizer (chain depth = 1)"|null|null|null
```

Start in text, automate in `ids`, archive in `json`. Reach
for `sarif` when a dashboard consumes the run, and `toon`
when a model does.
