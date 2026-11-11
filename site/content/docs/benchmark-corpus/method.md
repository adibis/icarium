---
title: Method
weight: 20
---

A case is a scenario with a verdict: `design.sv`, `design.sdc`,
and a `manifest.json` pinning the exact expected findings. The
manifest is ground truth — the runner diffs the checker against
it, never against an earlier run of the same checker.

## How verdicts read

A case passes on an exact match. Each `expect` entry pairs with
one finding by rule id plus one locator: a source `line`, or a
`dst` substring for port findings, which carry no source line.
No finding may be left over unless the manifest sets
`allow_extra`.

Firing cases plant one bug shape the rule must catch; silence
cases plant the approved pattern and require zero findings.
Silence guards precision: a checker that fires everywhere fails
the suite. `params` holds neutral checker parameters the
scenario needs (today only `sync_depth`, default 2). Strict
mode pins everything; `--ignore-notes` drops note-severity
verdicts on both sides for violation-oriented checkers.

## Running another checker

The case contract is tool-agnostic:

1. Elaborate `design.sv` with stock Yosys: `read_verilog -sv`,
   `hierarchy -check -top <top>`, `proc`, `flatten`. Four cases
   use `(* blackbox *)` macro models; a checker that flattens
   everything must treat black-box cells as opaque endpoints.
2. Apply `design.sdc`. The subset is five commands:
   `create_clock` (port roots, plus two virtual clocks),
   `create_generated_clock` (`-divide_by`), `set_clock_groups
   -asynchronous` (two or three groups), `set_input_delay
   -clock`, and one `set_output_delay -clock`. No Tcl
   substitution, no wildcards.
3. Compare findings to `expect` by (rule, line-or-dst), mapping
   the corpus rule ids to your own first. Silence cases must
   stay silent under your mapping too. Which endpoint each rule
   reports on is pinned per rule in the corpus
   [locator table](https://github.com/adibis/icarium_benchmark/blob/master/docs/locators.md);
   waiver-attribute spellings live in
   [attributes](https://github.com/adibis/icarium_benchmark/blob/master/docs/attributes.md).

## What the corpus does not assert

Verdicts that depend on tool-internal modeling — gate-structure
lint, memory opacity, reset-port policy — stay out. What the
corpus asserts, any correct checker should agree with; where
reasonable checkers disagree, the case doesn't belong here.
CDC-007 is reserved (no rule claims it).
