---
title: About icarium
linkTitle: About
---

icarium is an open-source structural CDC/RDC checker: Zig,
JSON-native, benchmarked against OpenTitan's own waivers up
to the full EarlGrey top.

- License: Apache-2.0 (see `LICENSE`).
- Source: [GitHub](https://github.com/adibis/icarium).
- Interchange: Accellera CDC/RDC 1.0 via Tcl converters;
  JSON schemas under `schema/` are the native contract.

Status: tier-3 complete — the full flat top checks streamed
in about an hour. See [Benchmarks]({{% relref "docs/benchmarks.md" %}}),
and [cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests), a
tool-neutral suite any CDC/RDC checker can run.
