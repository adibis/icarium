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
two clocks. The checker enumerates crossings pair by pair and
runs each rule over them, so a finding always names the two
ends and the clocks behind them.

## Synchronizer

The standard cure: two destination-domain flops in a row
(2FF). The first may go metastable, but it gets a full cycle
to settle before the second samples it. Two stages is the
default bar (`--sync-depth`, default 2); some rules ask for
more, and
every rule that vouches a chain checks its depth, its edges,
and what sits between its stages.

## Reset domain

Resets race too: when an async reset turns off (deasserts),
every flop it touches must leave reset together. A reset
domain is the set of flops sharing one release. RDC rules
apply the crossing idea to reset trees — release timed by a
foreign clock, combinational or muxed reset sources, and the
integrity of reset-synchronizer chains.

## Gray code

A multi-bit encoding in which one lane moves per transfer.
Lanes sampled mid-transfer still read a value the source
actually held, so no snapshot straddles two values. Gray is
one of the two approved ways to move a bus across domains;
the other is gating the bus behind a synchronized enable.

## Handshake

A request/acknowledge pair that sequences a transfer instead
of blindly sampling it: the source holds its payload until
the destination confirms the sample. Where a handshake
exists, the crossing rules that recognize it stay silent —
the protocol, not the chain, carries the safety argument.

## Finding

One reported verdict: a rule id, a severity, the endpoint it
pins, and the fix. Severities mean what they say — error is
a probable bug, warning needs a judgement call, note records
a structure worth reviewing. See the [rule catalog]({{%
relref "docs/rules/_index.md" %}}).

## Suppression

A recorded decision not to act on a finding: a waiver file
(JSON, with expiry dates), an RTL (register-transfer-level)
attribute where the structure is genuinely safe, a pragma
where the RTL cannot carry one, or a baseline that
grandfathers known debt. See
[Suppressions]({{% relref "docs/suppressions.md" %}}).

## Unknown

Flops icarium cannot assign to a clock domain — undeclared
ports, unmodeled cells, untyped boundaries. Unknowns get
their own findings (CDC-021, CDC-025) instead of silent
skips, because a domain the checker cannot see is a domain
it cannot verify.
