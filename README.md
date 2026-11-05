# icarium

Open-source structural CDC/RDC checker in Zig. Full-chip SystemVerilog,
JSON-native formats, Accellera 1.0 interchange.

Status: scaffold, netlist ingestion, SDC constraints.

## Build

Requires the Zig version in `pins.json` (check with
`sh scripts/check-pins.sh`).

```sh
zig build          # builds ./zig-out/bin/icarium
zig build test     # unit tests
```

## Layout

Small topic files; unit tests mirror `src` under `tests/`
(one `*_test.zig` per unit, aggregated by `tests/all.zig`).

- `src/main.zig` — CLI entry and dispatch
- `src/cli/` — argument matching, per-command runners
- `src/ir/` — elaborated-netlist ingestion (Module IR)
- `src/sdc/` — SDC subset parser and clock model (next chunk)
- `pins.json` — machine-readable dependency pins
- `bench/` — benchmark oracle, results, triage log
- `fixtures/` — paired bad/good rule fixtures

License: Apache-2.0 (see LICENSE).
