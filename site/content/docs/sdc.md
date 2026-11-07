---
title: SDC subset
weight: 11
---

# SDC subset

icarium reads a structural SDC subset: clocks, asynchrony, and
pin delays. Anything else warns and is skipped — except file
and process access (`source` and friends), which aborts the run.

## Supported verbs

| Verb | Meaning |
| ---- | ------- |
| `create_clock` | clock root: name, period, port/pin targets |
| `create_generated_clock` | divided/derived clock (`-divide_by`, `-combinational` div-by-1 alias) |
| `set_clock_groups -asynchronous` | groups that never meet in time |
| `set_clock_groups -logically_exclusive` | same, for muxed selects |
| `set_false_path` | pairs excluded from analysis |
| `set_input_delay` / `set_output_delay` | boundary timing context |

## Collections

`get_clocks`, `get_ports`, `get_cells`, `get_nets`, `get_pins`
all resolve with glob matching. `get_nets` splices net names
verbatim. Unmatched patterns warn; they never silently match
nothing.

## Case analysis

`set_case_analysis` is skipped in v1: constant propagation from
SDC is not modeled. Tie a source constant with `(* cdc_static *)`
instead (see [Suppressions]({{% relref "docs/suppressions.md" %}})).

Example SDC files ship per design under `bench/sdc/`.
