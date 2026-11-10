---
title: Contributing
weight: 40
---

# Contributing

One scenario per case: one bug shape, or one silence proof.
A case that needs two paragraphs to explain its verdict is two
cases.

## Anatomy

```
cases/tier1/<id>/
  design.sv      # the scenario, SystemVerilog-2012
  design.sdc     # clocks, async groups, port typing
  manifest.json  # id, top, sdc, expect, notes
```

Name the id after its target: `cdc<NN>_<shape>` or
`rdc<NN>_<shape>` for hand-authored scenarios. Keep the design
minimal — the smallest RTL that still exhibits the shape —
and comment the intent at the top, not the mechanism.

The manifest pins the verdict:

```json
{
  "id": "cdc001_async_data",
  "tier": 1,
  "design": "design.sv",
  "top": "cdc001_async_data",
  "sdc": "design.sdc",
  "expect": [
    {"rule": "CDC-001", "line": 11, "severity": "error"}
  ],
  "notes": "Unsynchronized flop-to-flop crossing across async groups. The capture flop must report."
}
```

Locate by source `line`, or by `dst` substring when the finding
names a port. Set `allow_extra` only when the verdict truly
varies by checker; set `params` only when the scenario needs a
non-default checker knob. Notes speak about the design, never
about the harness that built the case.

## Oracle discipline

Write the oracle from the rule contract, then run the case and
read any mismatch as a question, not a failure: either the
design exhibits more than you intended, or the checker sees
less than it should. Shrink the design before widening the
oracle. Silence cases earn their place the same way — an empty
`expect` must mean the approved pattern, not an accidentally
quiet design.

Regenerate the catalog (`python3 scripts/gen-catalog.py`) and
keep the suite green: `python3 run.py --icarium-bin <bin>`
must exit 0, in both strict and `--ignore-notes` modes.
