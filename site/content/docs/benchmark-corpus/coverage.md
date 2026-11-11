---
title: Coverage
weight: 30
---

Tier 1 holds 206 cases across 36 rules. Firing counts cases whose oracle expects the rule; silence counts empty-oracle cases built for it. Every rule fires in at least two cases; silence guards the rules whose approved pattern is worth pinning.

| rule | what it catches | firing | silence |
|---|---|---|---|
| CDC-001 | Unsynchronized control crossing | 13 | 8 |
| CDC-002 | Insufficient synchronizer depth | 3 | 2 |
| CDC-003 | Combinational logic on the way to a synchronizer | 4 | 3 |
| CDC-004 | Multi-bit bus crossing without gating or gray-coding | 4 | 5 |
| CDC-005 | Reconvergent synchronizers | 4 | 1 |
| CDC-006 | Glitchy combinational source on a control crossing | 5 | 1 |
| CDC-008 | Clock signal used as data | 3 | 4 |
| CDC-009 | Pulse-width risk on fast-to-slow data crossings | 4 | 2 |
| CDC-010 | Glitch on the clock network from a wrong-domain control signal | 5 | 2 |
| CDC-011 | Unconstrained primary input captured by clocked logic | 7 | 2 |
| CDC-012 | Gated bus crossing without synced-back handshake | 3 | 1 |
| CDC-013 | Toggle-synchronizer event loss on fast-to-slow crossing | 4 | 2 |
| CDC-014 | Combinational logic between synchronizer stages | 3 | 1 |
| CDC-015 | Synchronizer chain released by a foreign-domain reset | 4 | 1 |
| CDC-016 | Opposite-edge stages in a synchronizer chain | 4 | 1 |
| CDC-017 | Transparent latch in a CDC path | 4 | 1 |
| CDC-018 | Cascaded synchronizer chain past the depth threshold | 4 | 1 |
| CDC-019 | Independently-synced one-hot decode across CDC | 4 | 1 |
| CDC-020 | Sliced-bus reconvergence across CDC | 4 | 1 |
| CDC-021 | Flop clock driven by an undeclared port | 4 | 1 |
| CDC-022 | Synchronizer primitive shallower than required depth | 2 | 1 |
| CDC-023 | Clock net driven by a combine of declared clocks | 3 | 2 |
| CDC-024 | Single source fanning to multiple synchronizers | 9 | 2 |
| CDC-025 | Unresolved clock association | 5 | 1 |
| CDC-026 | Multiclock crossing leg-pair report | 13 | 1 |
| RDC-001 | Async reset released from a foreign clock domain | 6 | 1 |
| RDC-002 | Reset polarity mismatch on async reset distribution | 4 | 2 |
| RDC-003 | Sync reset driven from a foreign async domain | 5 | 1 |
| RDC-004 | Async reset driven by combinational logic | 3 | 1 |
| RDC-005 | Async reset from multiple independent sources | 5 | 0 |
| RDC-006 | Muxed async reset without a local synchronizer | 3 | 0 |
| RDC-007 | Reset synchronizer chain loads the asserted value | 5 | 0 |
| RDC-008 | Primary reset port unsynchronized in one domain | 5 | 0 |
| RDC-009 | Unqualified data crossing reset domains | 5 | 3 |
| RDC-010 | Reset synchronizer chain record and checks | 43 | 0 |
| RDC-011 | One net drives both sync and async resets | 5 | 2 |

Unattributed silence (`e2e_generated_clock`, `e2e_negedge_clock`):
end-to-end quiet designs with no single target rule.


Case-level verdicts live in the corpus repo: each case pairs
`design.sv` and `design.sdc` with a `manifest.json` pinning the
exact expected findings.

