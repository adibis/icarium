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
| `findings-1.1` | `check --format json` report: design, summary, rule groups; each endpoint names its netlist cell and its RTL signal |
| `findings-1.0` | the same report from icarium 0.1, without `signal` |
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

## Meridian waiver import

`icarium import-meridian --in WAIVERS.tcl --map bench/meridian_map.json
--out waivers.json` converts `set_rule_status` Tcl waiver files
(OpenTitan's Meridian waiver format) to native `waivers.json`
through a reviewed rule map that pins each foreign rule id to
its icarium equivalent. The Tcl stays outside the tool; JSON
is the contract. The same waivers drive the
[recall gate]({{% relref "docs/dev/recall.md" %}}).
