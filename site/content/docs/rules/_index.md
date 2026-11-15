---
title: Rule catalog
linkTitle: Rules
weight: 40
---

One page per rule: what it flags, which suppression marks it
honors, and the paired failing/passing fixtures. Pages are
generated from `icarium rules --doc` — see
`site/scripts/gen-rules.py`.

| Rule | Severity | What it flags |
| ---- | -------- | ------------- |
| [Unsynchronized control crossing](cdc-001/) (CDC-001) | error | The destination flop has no follow-on synchronizer in its own clock: a single-bit signal lands and is used directly, with no second stage to filter metastability. |
| [Insufficient synchronizer depth](cdc-002/) (CDC-002) | warning | A synchronizer chain exists but is shorter than the site minimum (--sync-depth, default 2): raise the depth or lower the bar. |
| [Combinational logic on the way to a synchronizer](cdc-003/) (CDC-003) | error | Source-domain signals combine through a gate before the synchronizer: the gate can glitch across source cycles and a 2FF cannot filter the transient. |
| [Multi-bit bus crossing without gating or gray-coding](cdc-004/) (CDC-004) | error | A multi-bit path crosses domains with no coherence mechanism: lanes settle on different cycles, so the destination can sample a value never sent. |
| [Reconvergent synchronizers](cdc-005/) (CDC-005) | warning | One source flop fans out to independent synchronizer chains whose outputs recombine downstream: each chain resolves metastability on its own cycle, so the recombination can see a value pair never true at the source. |
| [Glitchy combinational source on a control crossing](cdc-006/) (CDC-006) | error | A synchronizer first stage traces back through logic alone to top-level ports, with no registering flop: the chain can sample a transient no stable input ever held. |
| [Clock signal used as data](cdc-008/) (CDC-008) | error | A bit that drives a flop clock (or an SDC clock port) also feeds a non-clock input: clocks ride low-skew networks and sampling them as data breaks STA. |
| [Pulse-width risk on fast-to-slow data crossings](cdc-009/) (CDC-009) | warning | A single-bit flop crossing runs fast to slow (source period times 1.5 below the destination period) and the source flop is an edge detector: a 1-cycle pulse may slip between slow edges. |
| [Clock mux or gate control that can emit a runt pulse](cdc-010/) (CDC-010) | error | A clock mux select or gate enable can chop the output clock into runt pulses no sink synchronizer can heal. |
| [Unconstrained primary input captured by clocked logic](cdc-011/) (CDC-011) | warning | A top input with no set_input_delay clock typing reaches a flop D or SRST pin: one domain is a methodology warning, two or more an error no typing can silence. |
| [Gated bus crossing without synced-back handshake](cdc-012/) (CDC-012) | warning | A gated multi-bit crossing has no handshake holding the payload: the destination latches cycles after the request, by which time the source may have moved on. |
| [Toggle-synchronizer event loss on fast-to-slow crossing](cdc-013/) (CDC-013) | warning | A toggling source runs fast to slow past the period ratio: two toggles between destination samples cancel to zero edges and both events are silently lost. |
| [Combinational logic between synchronizer stages](cdc-014/) (CDC-014) | error | A gate sits between two stages of a synchronizer: the second stage may sample the first while still metastable, destroying the resolution time the chain was meant to provide. |
| [Synchronizer chain released by a foreign-domain reset](cdc-015/) (CDC-015) | error | A synchronizer chain takes its async reset from another clock domain: every foreign deassertion races the chain clock, so the resolving flops never reach steady state. |
| [Opposite-edge stages in a synchronizer chain](cdc-016/) (CDC-016) | error | Adjacent chain stages sample on opposite edges of one clock, halving the resolution time a same-edge chain would provide. |
| [Transparent latch in a CDC path](cdc-017/) (CDC-017) | error | A latch sits between a source flop and a destination flop in different clocks: while the enable holds, the foreign signal flows transparently to the destination with no resolution time. |
| [Cascaded synchronizer chain past the depth threshold](cdc-018/) (CDC-018) | warning | A destination chain runs deeper than the threshold (default 4): two stacked 2FF syncs, or a refactor leftover. |
| [Independently-synced one-hot decode across CDC](cdc-019/) (CDC-019) | warning | One comb decoder fans to two or more 1-bit source flops that cross to the same domain: lanes change together upstream but resolve apart, so the destination can sample combinations the encoder never emits. |
| [Sliced-bus reconvergence across CDC](cdc-020/) (CDC-020) | warning | A multi-bit source register fans lane by lane to two or more destinations in one domain: each lane resolves apart, so the destination can sample mixes the source never emits. |
| [Flop clock driven by an undeclared port](cdc-021/) (CDC-021) | error | A top-level input port drives flop clocks with no create_clock behind it. |
| [Synchronizer primitive shallower than required depth](cdc-022/) (CDC-022) | warning | A CDC macro carries its stage count as a parameter, not a flop chain, so CDC-002 cannot see it. |
| [Clock net driven by a combine of declared clocks](cdc-023/) (CDC-023) | warning | A gate mixes two or more declared clocks onto one net: the net glitches, runs at no declared frequency, and leaves its flops domainless. |
| [Single source fanning to multiple synchronizers](cdc-024/) (CDC-024) | warning | One source bit reaches two or more synchronizer chains: each chain resolves metastability on its own edge, so the set only holds when the destinations never recombine what they latched apart. |
| [Unresolved clock association](cdc-025/) (CDC-025) | warning | A crossing endpoint has no clock association: undriven flop clock, macro or memory output, unhandled primitive, or an untyped input the other port rules do not own. |
| [Multiclock crossing leg-pair report](cdc-026/) (CDC-026) | note | A crossing whose source or receiver runs on a muxed clock: each side may arrive on several legs, and one leg pair can be safe while another is not. |
| [Async reset released from a foreign clock domain](rdc-001/) (RDC-001) | error | A flop's async reset fans in from a register in another clock domain: every foreign deassertion races the local clock, so the flop never reaches a clean out-of-reset state. |
| [Reset polarity mismatch on async reset distribution](rdc-002/) (RDC-002) | error | A flop's async reset disagrees with its source: a producer flop drives a value the consumer never treats as assert, or a port declaration contradicts the pin. |
| [Sync reset driven from a foreign async domain](rdc-003/) (RDC-003) | error | A flop's synchronous reset fans in from a register in another clock domain. |
| [Async reset driven by combinational logic](rdc-004/) (RDC-004) | error | A flop's async reset pin is a comb gate's output fed by flops. |
| [Async reset from multiple independent sources](rdc-005/) (RDC-005) | warning | A flop's async reset combines two or more top-level ports with no flop behind the gate. |
| [Muxed async reset without a local synchronizer](rdc-006/) (RDC-006) | warning | A flop's async reset is driven directly by a mux: selection is explicit, but the selected leg still deasserts async to the consumer clock. |
| [Reset synchronizer chain loads the asserted value](rdc-007/) (RDC-007) | error | A reset synchronizer chain whose head D ties to the asserted value never deasserts: on release it reloads assertion and holds every downstream consumer in reset forever. |
| [Primary reset port unsynchronized in one domain](rdc-008/) (RDC-008) | error | A top-level reset port fans straight into flops of a domain with no reset synchronizer, while another domain syncs the same port: the builder knew, then missed a domain. |
| [Unqualified data crossing reset domains](rdc-009/) (RDC-009) | error | A flop's data input is driven from another reset domain with no shared release: the source can come out of reset while the receiver samples. |
| [Reset synchronizer chain record and checks](rdc-010/) (RDC-010) | note | Every recognized reset synchronizer is recorded for review: stages, clock, polarity, head constant, async root. |
| [One net drives both sync and async resets](rdc-011/) (RDC-011) | error | One resolved reset root reaches an async pin on some flop and a sync control ($sdff SRST or a const-leg D-mux) on another. |
