---
title: SDC subset
weight: 11
---

icarium reads a structural SDC (Synopsys Design Constraints)
subset: clocks, asynchrony, and pin delays. Anything else
warns and is skipped — except file and process access
(`source`, `exec`, `open`, `load`, `file`, `socket`), which
aborts the run.

## Supported verbs

| Verb | Meaning |
| ---- | ------- |
| `create_clock` | clock root: name, period, port/pin targets |
| `create_generated_clock` | divided/derived clock (`-divide_by`, `-multiply_by`; `-combinational` passes through at the same frequency) |
| `set_clock_groups -asynchronous` | groups that never meet in time |
| `set_clock_groups -logically_exclusive` | muxed-clock groups, treated as async (they never meet in time) |
| `set_clock_groups -physically_exclusive` | same, for physically exclusive clocks |
| `set_false_path` | pairs excluded from analysis |
| `set_input_delay` / `set_output_delay` | boundary timing context |

## Clock relations

Clocks are related unless the SDC says otherwise, as in timing
analysis. `set_clock_groups` makes a pair asynchronous, and the
metastability rules (missing or shallow synchronizers, logic
before a synchronizer, reconvergence, unsafe buses) report only
on asynchronous pairs. Rules about rates, such as a pulse or a
toggle crossing fast to slow (CDC-009, CDC-013), use the declared
periods and apply to related clocks too.

## Collections

`get_clocks`, `get_ports`, `get_cells`, `get_nets`, `get_pins`
all resolve with glob matching. `get_nets` matches net names
literally, exactly as written in the netlist. An unmatched
pattern always warns — an empty match is never silent.

## Case analysis

`set_case_analysis` is skipped: constant propagation from
SDC is not modeled. Tie a source constant with `(* cdc_static *)`
instead (see [Suppressions]({{% relref "docs/suppressions.md" %}})).

Example SDC files ship per design under `bench/sdc/`.
