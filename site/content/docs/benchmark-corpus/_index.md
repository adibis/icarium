---
linkTitle: "Corpus"
title: Benchmark corpus
weight: 40
---

The corpus is an independent CDC/RDC benchmark: small designs with
known-good verdicts, so any checker can measure recall and precision
against ground truth instead of against another tool's output. It
lives in its own repository,
[icarium_benchmark](https://github.com/adibis/icarium_benchmark),
under Apache-2.0.

## Tiers

- **Tier 1** — 206 micro-cases across all 36 rules, each with firing
  or silence verdicts. 60 cases expect silence; 7 pass neutral
  checker params; every rule fires in at least two cases. Shipped.
- **Tier 2** — OpenTitan positives: real waiver-backed violations
  traced to endpoints. Planned.
- **Tier 3** — negatives: clean production modules that must stay
  quiet. Planned.

## Run it

Against icarium:

```sh
git clone https://github.com/adibis/icarium_benchmark
cd icarium_benchmark
python3 run.py --icarium-bin /path/to/icarium
```

Needs `yosys` on PATH and an icarium binary. Exit 0 when every
case matches its manifest. The corpus elaborates with Yosys 0.70;
designs use SystemVerilog-2012 plus `(* blackbox *)` stubs, and
the runner needs Python 3 with the standard library.

Against another checker, run your own tool over the same cases —
the [method]({{% relref "docs/benchmark-corpus/method.md" %}}) is three
steps and tool-agnostic.

## Read further

- [Method]({{% relref "docs/benchmark-corpus/method.md" %}}) — how
  verdicts read, and what the corpus does not assert.
- [Coverage]({{% relref "docs/benchmark-corpus/coverage.md" %}}) —
  per-rule firing and silence counts.
- [Contributing]({{% relref "docs/benchmark-corpus/contributing.md" %}}) —
  how to add a case.
