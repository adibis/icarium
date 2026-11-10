---
title: Formats
weight: 12
---


icarium is JSON-native: every artifact it reads or writes is a
versioned JSON schema under `schema/`. Tcl exists only at the
edges, as converters.

## Schemas

| Schema | Artifact |
| ------ | -------- |
| `findings-1.0` | `check --format json` report: design, summary, rule groups |
| `waivers-1.0` | native waivers (`check --waivers`) |
| `clock-map-1.0` | `--emit-domain-map`: clocks, generated clocks, flop domains |
| `reset-map-1.0` | `--emit-reset-domain-map`: reset sources, chains, crossings |
| `reset-hints-1.0` | `--reset-hints`: external reset polarities and sync cells |
| `sarif-2.1.0` | `check --format sarif` for code-scanning dashboards |

`scripts/validate-schemas.sh` validates native artifacts in CI.

## TOON

`--format toon` emits a token-efficient tabular rendering of the
same findings for LLM pipelines. TOON is emit-only: icarium
never parses it back.

## Accellera 1.0 interchange

`import-meridian` converts `set_rule_status` Tcl waiver files to
native `waivers.json` through a signed rule map
(`bench/meridian_map.json`). The Tcl stays outside the tool;
JSON is the contract.
