---
title: Rule catalog
linkTitle: Rules
weight: 40
---

One page per rule: what it flags, which suppression marks it
honors, and the paired failing/passing fixtures. Pages are
generated from `icarium rules --doc` — see
`site/scripts/gen-rules.py`.

| Rule | Severity | Title |
| ---- | -------- | ----- |
| [CDC-001](cdc-001/) | error | Unsynchronized control crossing |
| [CDC-002](cdc-002/) | warning | Insufficient synchronizer depth |
| [CDC-003](cdc-003/) | error | Combinational logic on the way to a synchronizer |
| [CDC-004](cdc-004/) | error | Multi-bit bus crossing without gating or gray-coding |
| [CDC-005](cdc-005/) | warning | Reconvergent synchronizers |
| [CDC-006](cdc-006/) | error | Glitchy combinational source on a control crossing |
| [CDC-008](cdc-008/) | error | Clock signal used as data |
| [CDC-009](cdc-009/) | warning | Pulse-width risk on fast-to-slow data crossings |
| [CDC-010](cdc-010/) | error | Glitch on the clock network from a wrong-domain control signal |
| [CDC-011](cdc-011/) | warning | Unconstrained primary input captured by clocked logic |
| [CDC-012](cdc-012/) | warning | Gated bus crossing without synced-back handshake |
| [CDC-013](cdc-013/) | warning | Toggle-synchronizer event loss on fast-to-slow crossing |
| [CDC-014](cdc-014/) | error | Combinational logic between synchronizer stages |
| [CDC-015](cdc-015/) | error | Synchronizer chain released by a foreign-domain reset |
| [CDC-016](cdc-016/) | error | Opposite-edge stages in a synchronizer chain |
| [CDC-017](cdc-017/) | error | Transparent latch in a CDC path |
| [CDC-018](cdc-018/) | warning | Cascaded synchronizer chain past the depth threshold |
| [CDC-019](cdc-019/) | warning | Independently-synced one-hot decode across CDC |
| [CDC-020](cdc-020/) | warning | Sliced-bus reconvergence across CDC |
| [CDC-021](cdc-021/) | error | Flop clock driven by an undeclared port |
| [CDC-022](cdc-022/) | warning | Synchronizer primitive shallower than required depth |
| [CDC-023](cdc-023/) | warning | Clock net driven by a combine of declared clocks |
| [CDC-024](cdc-024/) | warning | Single source fanning to multiple synchronizers |
| [CDC-025](cdc-025/) | warning | Unresolved clock association |
| [CDC-026](cdc-026/) | note | Multiclock crossing leg-pair report |
| [RDC-001](rdc-001/) | error | Async reset released from a foreign clock domain |
| [RDC-002](rdc-002/) | error | Reset polarity mismatch on async reset distribution |
| [RDC-003](rdc-003/) | error | Sync reset driven from a foreign async domain |
| [RDC-004](rdc-004/) | error | Async reset driven by combinational logic |
| [RDC-005](rdc-005/) | warning | Async reset from multiple independent sources |
| [RDC-006](rdc-006/) | warning | Muxed async reset without a local synchronizer |
| [RDC-007](rdc-007/) | error | Reset synchronizer chain loads the asserted value |
| [RDC-008](rdc-008/) | error | Primary reset port unsynchronized in one domain |
| [RDC-009](rdc-009/) | error | Unqualified data crossing reset domains |
| [RDC-010](rdc-010/) | note | Reset synchronizer chain record and checks |
| [RDC-011](rdc-011/) | error | One net drives both sync and async resets |
