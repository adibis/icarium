# icarium

Open-source structural CDC/RDC checker in Zig. Elaborated
SystemVerilog in, findings out — JSON-native, benchmarked
against OpenTitan's own waivers up to the full EarlGrey top.

## Status

36 rules (CDC-001–026 minus reserved 007, RDC-001–011), six
report formats, streamed full-chip checking. See the
[docs](https://adibis.github.io/icarium/) for usage,
rule reference, and benchmarks.

## Build

```sh
zig build          # ./zig-out/bin/icarium
zig build test     # unit tests
```

Yosys 0.70 on `PATH` enables elaboration and the
end-to-end suite. Pins live in `pins.json`; check them with
`sh scripts/check-pins.sh`.

## Check a design

```sh
sh scripts/elaborate.sh --top spi_device --out spi.json design.sv
./zig-out/bin/icarium check --yosys-json spi.json --top spi_device --sdc spi.sdc
```

## Layout

- `src/` — the checker, one concern per directory
- `tests/` — unit tests mirroring `src`, plus `e2e/`
- `fixtures/` — paired failing/passing SystemVerilog per rule
- `schema/` — versioned JSON contracts
- `bench/` — differentials, recall gate, reports
- `site/` — documentation source (Hugo)
- `submodules/icarium_benchmark/` — separate benchmark
  corpus repo (nested checkout, own history)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). One concern per
PR; new behavior needs a fixture or e2e case.

## License

Apache-2.0; see [LICENSE](LICENSE).
