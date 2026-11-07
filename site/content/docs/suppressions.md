---
title: Suppressions
weight: 13
---

# Suppressions

Four mechanisms, from most local to most global. All of them
annotate findings; none of them delete crossings.

## Verilog attributes

Assert intent in the RTL where the structure is genuinely safe:

| Mark | Meaning |
| ---- | ------- |
| `(* cdc_sync *)` / `(* async_reg *)` | vetted synchronizer cell |
| `(* cdc_static *)` | source held constant |
| `(* cdc_handshake *)` | capture register of a handshake |
| `(* reset_sync *)` / `(* reset_synchronizer *)` | vetted reset synchronizer |

Each [rule]({{% relref "docs/rules/_index.md" %}}) lists the marks it honors.

## Waiver files

`--waivers FILE` applies native JSON waivers with expiry dates;
`--strict-waivers` fails the run on waivers that match nothing,
so stale waivers surface instead of rotting. Unmatched waiver
ids are reported in the JSON output.

## Baselines

`--baseline FILE` carries over matching prior findings, so only
new findings fail the run. Useful for adopting the checker on a
design with known debt.

## Pragmas and scan

`// icarium: disable-rule CDC-001 reason...` comments waive by
source location when the waived RTL cannot carry an attribute.
`--ignore-scan-mode` waives scan-tagged clock and reset paths.
