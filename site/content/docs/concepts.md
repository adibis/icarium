---
title: Concepts
weight: 3
---

Everything icarium reports traces back to one physical fact: a
flop (flip-flop) that samples its input while the input is
changing can hang between 0 and 1, then settle late — or
wrong. That is metastability, and every crossing discipline
below exists to contain it.

## Domain

A clock domain is the set of flops ticked by one clock. Two
clocks the SDC file declares asynchronous form two domains
(see [SDC subset]({{% relref "docs/sdc.md" %}})); a divided or
muxed clock forms its own. icarium assigns every flop to a
domain by tracing its clock pin back through the netlist to
a declared root.

## Crossing

A crossing is a signal path that starts in one domain and is
sampled in another: source flop, destination flop, and the
two clocks. Either end can also be a typed port — a clocked
input driving a flop, or a flop driving an output — but a
crossing always has a sampling flop on at least one side.
What is not a crossing: a path inside one domain (no clock
change, nothing to check), and pure port-to-port
combinational logic (no flop, nothing to sample). The
checker enumerates crossings pair by pair and runs each
rule over them, so a finding always names the two ends and
the clocks behind them.

## Synchronizer

The standard cure: two destination-domain flops in a row
(2FF). The first may go metastable, but it gets a full cycle
to settle before the second samples it. Two stages is the
default bar (`--sync-depth`, default 2); raise the bar and
CDC-002 (flop chains) and CDC-022 (macro parameters) flag
what falls short. Between the stages, buffers are wire and
stay silent; a gate fires CDC-014, because the second stage
may sample the first while still metastable.

## Reset domain

Resets race too: when an async reset turns off (deasserts),
every flop it touches must leave reset together. A reset
domain is the set of flops sharing one release. The
canonical failure is RDC-001: a flop in `cb` takes its async
reset from a register in `ca`, so every `ca` release races
the `cb` clock and the flop can come out of reset a cycle
late — or metastable. The remaining RDC rules cover
combinational or muxed reset sources and the integrity of
reset-synchronizer chains.

## Gray code

A multi-bit encoding in which one lane moves per transfer.
Lanes sampled mid-transfer still read a value the source
actually held, so no snapshot straddles two values. Gray
fits values sampled every cycle — counters, pointers. A bus
the destination can wait for wants gating instead: the
source holds the payload behind a synchronized enable until
a synced-back strobe confirms the sample. Pick wrong and
the checker tells you: a gated bus with no holding
handshake fires CDC-012. (Asserting `(* cdc_gray *)` on a
bus that is not actually gray is worse — the checker trusts
the promise and stays silent.)

## Handshake

A request/acknowledge pair that sequences a transfer instead
of blindly sampling it: the source holds its payload until
the destination confirms the sample. The crossing rules
that recognize a handshake — CDC-001, CDC-012, CDC-013,
CDC-014, CDC-020 — stay silent where one exists: the
protocol, not the chain, carries the safety argument.

## Finding

One reported verdict: a rule id, a severity, the endpoint it
pins, and the fix. [Reading a
finding]({{% relref "docs/guides/reading-findings.md" %}})
decodes one line by line; the [rule catalog]({{%
relref "docs/rules/_index.md" %}}) defines every rule.

## Suppression

A recorded decision not to act on a finding: a waiver file
(JSON, with expiry dates), an RTL (register-transfer-level)
attribute where the structure is genuinely safe, a pragma
where the RTL cannot carry one, or a baseline that
grandfathers known debt. The default is the waiver file:
dated, reviewable, expiring. Reach for an attribute when
the structure is permanently safe and the RTL can carry the
mark; for a pragma when it cannot; for a baseline when
adopting the checker onto a design with known debt. See
[Suppressions]({{% relref "docs/suppressions.md" %}}).

## Unknown

Flops icarium cannot assign to a clock domain — undeclared
ports, unmodeled cells, untyped boundaries. Unknowns get
their own findings (CDC-021, CDC-025) instead of silent
skips, because a domain the checker cannot see is a domain
it cannot verify.
