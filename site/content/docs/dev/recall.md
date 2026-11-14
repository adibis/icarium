---
title: Recall gate
weight: 63
---

OpenTitan ships CDC/RDC waivers for EarlGrey. icarium treats
them as the benchmark: with no waiver file applied, the tool
must catch everything the waivers excuse. `bench/recall.py`
measures that.

## How it works

`bench/oracle.py` builds a waiver oracle from the 18 Meridian
waiver files through a signed rule map
(`bench/meridian_map.json`, pinned to OpenTitan `c2dbfc95`).
Each in-scope oracle entry gets one verdict:

- **full / partial** — a mapped rule fired overlapping both /
  one endpoint. A waiver naming a single endpoint reaches
  full on that one end; the oracle cannot ask for more than
  the waiver names.
- **rule-only** — a mapped rule fired on the block but reaches
  neither waived endpoint.
- **missed** — nothing fired and no CDC-011/021/025 finding
  overlaps: true misses, must stay near zero.
- **modeling-gap** — only CDC-011/021/025 overlap: the checker
  sees the structure but cannot clock it yet.

Entries stay pending — counted, never in the denominator —
when their rules are reserved-only, when the entry names no
endpoints (clock-model), when its endpoints lie outside the
checked netlist (out-of-scope), or when judging needs the
full chip (chip-scope, measured only with `--chip`). Extras
never block — recall counts what the waivers excuse that the
checker also flags.

## Running it

```sh
YOSYS_SLANG=<slang-yosys> python3 bench/recall.py --enforce
```

`--enforce` fails on any miss, new modeling gap, verdict
downgrade, or dropped entry versus the blessed baseline
(`bench/recall_baseline.json`); `--bless` re-blesses after a
deliberate scope change. Misses are never blessed; blessed
gaps hold as tripwires. Needs fusesoc plus slang-capable
Yosys for the tier-2 netlists, so CI does not gate it.
`--chip` additionally measures the chip-scope entries
against a streamed full-top run (about an hour plus
matching).

Current state: 465 blessed entries (58 full, 230 partial,
176 rule-only), zero missed, 1 modeling-gap tripwire. The
gate holds: misses fail the run, and the tripwire fails it
if the gap count moves without a re-bless.
