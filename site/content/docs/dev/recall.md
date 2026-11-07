---
title: Recall gate
weight: 63
---

# Recall gate

OpenTitan ships CDC/RDC waivers for EarlGrey. icarium treats
them as the benchmark: with no waiver file applied, the tool
must catch everything the waivers excuse. `bench/recall.py`
measures that.

## How it works

`bench/oracle.py` builds a waiver oracle from the 19 Meridian
waiver files through a signed rule map
(`bench/meridian_map.json`, pinned to OpenTitan `c2dbfc95`).
Each in-scope oracle entry gets one verdict:

- **full / partial** — a mapped rule fired overlapping both /
  one endpoint. Single-ended waivers reach full on their one
  end: weaker evidence, counted honestly.
- **rule-only** — a mapped rule fired on the block but reaches
  neither waived endpoint.
- **missed** — nothing fired and no unknown-family finding
  overlaps: true misses, must stay near zero.
- **modeling-gap** — only CDC-011/021/025 overlap: we see the
  structure but cannot clock it yet.

Entries outside measurement (reserved-only, clock-model,
out-of-scope, chip-scope) stay pending: counted, never in
the denominator. Extras never block — recall counts what the
waivers excuse that we also flag.

## Running it

```sh
YOSYS_SLANG=<slang-yosys> python3 bench/recall.py --enforce
```

`--enforce` fails on any miss, modeling gap, verdict
downgrade, or dropped entry versus the blessed baseline
(`bench/recall_baseline.json`); `--bless` re-blesses after a
deliberate scope change. Needs fusesoc plus slang-capable
Yosys for the tier-2 netlists, so CI does not gate it.

Current state: spi_device 11/11 endpoint recall, zero missed
everywhere measured, 528 chip-scope entries pending the
full-top netlist they name.
