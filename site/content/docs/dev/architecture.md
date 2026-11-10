---
title: Architecture
weight: 61
---


Small topic files, CMSIS/Linux style: each `src/<area>/` holds
one concern, each `src/<area>.zig` re-exports it.

## Pipeline

![icarium pipeline](/images/overview/pipeline.svg)

## Modules

| Module | Owns |
| ------ | ---- |
| `ir` | Yosys JSON ingestion, Module IR, bit tables |
| `sdc` | constraint lexer/parser, clock model |
| `clock` | structural clock tracing, root resolution |
| `reset` | reset tracing, synchronizer-chain detection |
| `sync` | domain table, chain-depth and bus-verdict memos |
| `crossing` | pair walking, chunking, crossing records |
| `rule` | registry, per-batch/per-range/once passes, 36 rules |
| `report` | findings writers (text, JSON, SARIF, TOON, maps) |
| `suppress` | attributes, waivers, baselines, pragmas |
| `cli` | argument parsing, per-command runners |

## Memory discipline

Zig arenas with explicit lifetimes: batch transients die per
chunk, walk scratch dies per flop, and only findings plus
small accumulators survive the run. Arena free is a no-op, so
throwaway arenas root at the real allocator — never nested
inside another arena. See [Streaming]({{% relref "docs/dev/streaming.md" %}}).
