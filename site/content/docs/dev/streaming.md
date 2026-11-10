---
title: Streaming
weight: 62
---


`--stream` checks designs no materialized report can hold by
consuming each walked chunk through the rules immediately and
keeping only findings plus small accumulators.

![streamed checking](/images/overview/streaming.svg)

## How a run flows

1. Sources split into cell-run-aligned chunks (chunk edges
   never split a cell's lanes, so bus groups stay whole).
2. Each chunk walks to crossings; per-crossing rules run on
   the batch; batch transients die with the batch.
3. Group rules accumulate: per-range ledgers finish at range
   ends, minima instead of exact pair sets where the rule
   allows it.
4. Once rules (clock/reset structure) run a single pass at
   the end; accumulator rules finish; findings sort
   canonically and dedupe globally by waiver identity.

## Guarantees

- **Same findings**: streamed output matches the materialized
  run on every tier-2 design (byte-identical modulo witness
  order on one), and forced tiny pair-budgets reproduce the
  default run exactly.
- **Bounded peak**: dense runs past the pair budget split by
  destination cell, so peak memory follows one budget of
  crossings, never the widest broadcast.

Tune with `--stream-chunk` (default 256 sources),
`--pair-budget` (default 2M pairs), and `--progress` for a
per-chunk `pairs/crossings/findings` line on stderr.
