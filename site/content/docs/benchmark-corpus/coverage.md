---
title: Coverage
weight: 30
---

Tier 1 holds 206 cases across 36 rules. Firing counts cases whose oracle expects the rule; silence counts empty-oracle cases built for it. Every rule fires in at least two cases; silence guards the rules whose approved pattern is worth pinning.

| rule | firing | silence |
|---|---|---|
| CDC-001 | 13 | 8 |
| CDC-002 | 3 | 2 |
| CDC-003 | 4 | 3 |
| CDC-004 | 4 | 5 |
| CDC-005 | 4 | 1 |
| CDC-006 | 5 | 1 |
| CDC-008 | 3 | 4 |
| CDC-009 | 4 | 2 |
| CDC-010 | 5 | 2 |
| CDC-011 | 7 | 2 |
| CDC-012 | 3 | 1 |
| CDC-013 | 4 | 2 |
| CDC-014 | 3 | 1 |
| CDC-015 | 4 | 1 |
| CDC-016 | 4 | 1 |
| CDC-017 | 4 | 1 |
| CDC-018 | 4 | 1 |
| CDC-019 | 4 | 1 |
| CDC-020 | 4 | 1 |
| CDC-021 | 4 | 1 |
| CDC-022 | 2 | 1 |
| CDC-023 | 3 | 2 |
| CDC-024 | 9 | 2 |
| CDC-025 | 5 | 1 |
| CDC-026 | 13 | 1 |
| RDC-001 | 6 | 1 |
| RDC-002 | 4 | 2 |
| RDC-003 | 5 | 1 |
| RDC-004 | 3 | 1 |
| RDC-005 | 5 | 0 |
| RDC-006 | 3 | 0 |
| RDC-007 | 5 | 0 |
| RDC-008 | 5 | 0 |
| RDC-009 | 5 | 3 |
| RDC-010 | 43 | 0 |
| RDC-011 | 5 | 2 |

Unattributed silence (`e2e_generated_clock`, `e2e_negedge_clock`):
end-to-end quiet designs with no single target rule.


Case-level oracles live in the corpus repo: each case pairs
`design.sv` and `design.sdc` with a `manifest.json` pinning the
exact expected findings.

