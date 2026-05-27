# icarium

A daemon-first orchestration engine for chip design verification (DV). Icarium
receives natural-language or structured commands, routes them to multi-step
pipeline definitions called **gears**, and manages parallel LLM calls and
simulation processes to drive DV tasks to completion.

Icarium defines `schema/plugin_schema.json` — the contract that knowledge-graph
indexer plugins must follow. What consumes that data is outside icarium's scope.

---

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| Zig | 0.14+ | `brew install zig` |
| PostgreSQL | 16+ | `brew install postgresql@16` |
| pgvector | 0.7+ | `brew install pgvector` |
| libpq | (with PG) | headers in `/opt/homebrew/opt/postgresql@16/include` |
| ONNX Runtime | 1.17+ | for the NER indexer plugin only |

The daemon (`icariumd`) and CLI (`icarium`) have **no ONNX dependency**. Only the
`icarium-indexer-codebert` plugin binary needs ONNX Runtime.

---

## Build

```sh
# daemon + CLI only (no ONNX)
zig build

# full build including the NER plugin (requires ONNX Runtime)
zig build \
  -Donnxruntime-include=/opt/homebrew/include/onnxruntime \
  -Donnxruntime-lib=/opt/homebrew/lib

# run C smoke tests (NER layer)
zig build test
```

Build outputs in `zig-out/bin/`:
- `icariumd` — the daemon
- `icarium` — CLI client
- `icarium-indexer-codebert` — built-in NER extractor plugin

Override library search paths if your PostgreSQL lives elsewhere:

```sh
zig build \
  -Dpq-include=/usr/include/postgresql \
  -Dpq-lib=/usr/lib
```

---

## Quick Start

```sh
# 1. Create the database
createdb icarium

# 2. Apply the schema
psql icarium -f schema/001_init.sql

# 3. Initialise config in your project root
icarium init

# 4. Start the daemon
icariumd start

# 5. Verify
icarium status

# 6. Index your SV/UVM project
icarium index --project myproject --root /path/to/testbench

# 7. Query indexed entities
echo '{"method":"query","type":"entities","kind":"UVM_AGENT"}' | nc -U /tmp/icarium.sock
```

---

## Configuration (`icarium.toml`)

`icarium init` writes a template. Key sections:

```toml
[indexer]
plugin    = "icarium-indexer-codebert"   # extractor plugin on $PATH
models_dir = ""                           # default: $ICARIUM_MODELS

[db]
conninfo = "dbname=icarium host=localhost"

[daemon]
socket    = "/tmp/icarium.sock"
log_level = "info"

[llm]
# endpoint = "https://api.anthropic.com/v1"
# model    = "claude-sonnet-4-6"
# api_key_env = "ANTHROPIC_API_KEY"
# — or any OpenAI-compatible endpoint:
# endpoint = "http://localhost:11434/v1"
# model    = "qwen2.5-coder:32b"
```

---

## CLI Commands

```
icariumd start     Daemonize and start listening on /tmp/icarium.sock
icariumd stop      Send SIGTERM to the running daemon
icariumd status    Check daemon health and print task queue stats

icarium init       Write icarium.toml in the current directory
icarium index      Trigger incremental NER index (also called by git hook)
```

---

## IPC Protocol

All communication is newline-delimited JSON over the Unix socket at
`/tmp/icarium.sock`. One request per connection; the daemon writes one response
and closes.

```sh
# generic client one-liner
echo '<json>' | nc -U /tmp/icarium.sock
```

### Core methods

```jsonc
// Health check
{"method": "ping"}
→ {"result": "pong"}

// Daemon + task queue status
{"method": "status"}
→ {"result": {"state": "running", "tasks": {"total": 3, "pending": 1, "running": 1}}}

// Submit a shell task
{"method": "task.submit", "cmd": "make sim", "kind": "shell"}
→ {"result": {"id": 7, "state": "pending"}}

// List recent tasks (last 20)
{"method": "task.list"}
→ {"result": [{"id": 7, "kind": "shell", "state": "done", "exit_code": 0, ...}]}
```

### Entity queries

Query the local entity store built by indexer plugins. All parameters except
`type` are optional filters.

```jsonc
// List entities by kind or name pattern
{"method": "query", "type": "entities", "kind": "UVM_AGENT"}
{"method": "query", "type": "entities", "name": "axi*"}

// Relation graph hop
{"method": "query", "type": "relations", "from": "axi_agent", "rel": "HAS_DRIVER"}

// Assembled context centered on an entity
{"method": "query", "type": "context", "focus": "dma_agent", "depth": 1}

// UVM agents with no covergroup — coverage gap report
{"method": "query", "type": "no_covergroup"}
{"method": "coverage_gaps"}
```

Add `"project": "myproject"` to scope any query to a named project.

### Gear lookup

```jsonc
{"method": "gear.find", "q": "close coverage"}
→ {"result": {"name": "close_coverage", "stages": 5, "triggers": 4}}
```

### Kanban board

```jsonc
{"method": "kanban.add",  "params": {"title": "close AXI coverage", "gear": "close_coverage", "priority": 80}}
→ {"task_id": "a1b2c3...", "status": "triage"}

{"method": "kanban.list", "params": {"status": "todo", "limit": 20}}
{"method": "kanban.get",  "params": {"task_id": "a1b2c3..."}}
{"method": "kanban.move", "params": {"task_id": "a1b2c3...", "status": "done"}}
{"method": "kanban.link", "params": {"parent_id": "...", "child_id": "..."}}
```

Kanban task statuses: `triage → todo → ready → running → blocked → review → done | archived`

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  icariumd                                           │
│                                                     │
│  Unix socket accept loop (single-threaded)          │
│    └── ipc.zig — method routing                     │
│                                                     │
│  Executor thread (queue.zig)                        │
│    └── runs shell/index/triage tasks                │
│    └── fires hooks on state changes                 │
│                                                     │
│  Entity store queries (db.c → libpq)                │
│    └── entities, relationships indexed by plugins   │
│                                                     │
│  Gear registry (gear_registry.zig)                  │
│    └── loads *.gear files from gears/, ~/.icarium/  │
│                                                     │
│  Plugin registry (plugin_registry.zig)              │
│    └── kanban (in-process, plugins/kanban.zig)      │
│    └── extractor plugins (short-lived subprocesses) │
└─────────────────────────────────────────────────────┘
         │ libpq
┌────────▼────────────────────────────────────────────┐
│  PostgreSQL                                         │
│  entities, relationships, tasks, findings           │
│  kanban_tasks, kanban_task_links, kanban_events     │
│  pgvector (embedding vector(768) on entities)       │
└─────────────────────────────────────────────────────┘
```

### Source layout

```
src/c/
  db.c / db.h          PostgreSQL interface (libpq): entities, tasks,
                       entity store queries, kanban CRUD
  validate.c / .h      NDJSON record validator for plugin output
  infer.c / .h         ONNX Runtime inference (NER model)
  tok.c / .h           BPE tokeniser (matches GraphCodeBERT vocab)
  index.c / .h         Entity extraction pipeline (tok → infer → emit)
  plugin_main.c        icarium-indexer-codebert binary entry point

src/zig/
  main.zig             CLI entry point: init / start / stop / status / index
  daemon.zig           Double-fork, pidfile, socket accept loop, startup init
  ipc.zig              IPC method dispatch (all JSON-over-Unix-socket handlers)
  queue.zig            In-memory task queue + executor thread
  gothos.zig           Entity store query wrappers (db.c → IPC handlers)
  gear.zig             Gear file parser (YAML-like, arena-allocated)
  gear_registry.zig    Gear discovery: ICARIUM_GEARS, ./gears/, ~/.icarium/gears/
  plugin_registry.zig  Plugin manifest parser + in-process capability dispatch
  hooks.zig            Fire-and-forget hook registry (64 slots)
  plugins/kanban.zig   Kanban capability plugin (handles kanban.* methods)
  plugin_runner.zig    Extractor plugin subprocess runner
  config.zig           icarium.toml parser
  index_cmd.zig        `icarium index` subcommand
  setup.zig            `icarium init` subcommand
  cli.zig              Shared CLI utilities
  c.zig                C FFI bindings import
```

---

## Database Schema

Applied automatically at daemon startup. Manual application:
`psql icarium -f schema/001_init.sql`.

```
entities           NER-extracted SV/UVM entities (kind, name, file, line, confidence,
                   embedding vector(768))
relationships      Directed structural edges between entities (kind, from_id, to_id)
tasks              Daemon task queue (shell / index / triage jobs)
findings           Structured LLM analysis results
icarium_projects   Named projects with root paths
kanban_tasks       Kanban board cards (9 statuses, gear_name, gear_run_id)
kanban_task_links  Parent/child dependency edges between cards
kanban_events      Audit trail (status changes, comments, finding links)
```

Entity kinds indexed by the built-in NER model:
`MODULE` `PORT` `PARAMETER` `PACKAGE` `INTERFACE` `COVERGROUP` `ASSERTION`
`UVM_AGENT` `UVM_DRIVER` `UVM_MONITOR` `UVM_SEQUENCER` `UVM_SCOREBOARD`
`UVM_ENV` `UVM_TEST` `UVM_SEQUENCE` `CLASS`

---

## Plugin Contract

Icarium publishes `schema/plugin_schema.json` — the NDJSON record format that
all extractor plugins must emit. Each line is either an entity or a relation:

```jsonc
// Entity record
{"kind": "entity", "type": "UVM_AGENT", "name": "axi_agent",
 "file": "tb/axi_agent.sv", "line_start": 12, "line_end": 89,
 "confidence": 0.97}

// Relation record
{"kind": "relation", "type": "HAS_DRIVER",
 "from_kind": "UVM_AGENT", "from_name": "axi_agent",
 "to_kind": "UVM_DRIVER", "to_name": "axi_driver",
 "confidence": 0.90}
```

Icarium validates every record from every plugin against this schema before
ingesting it. Any system that consumes the entity/relation tables — whether a
graph database, a vector store, or an analysis tool — works from this contract.

---

## Plugin System

Icarium supports two plugin kinds, both declared via a `plugin.yaml` manifest.

### Extractor plugins

Short-lived subprocesses. Read file paths from stdin, write NDJSON records to
stdout conforming to `schema/plugin_schema.json`.

```yaml
name: icarium-indexer-codebert
kind: extractor
emits_kinds: [UVM_AGENT, UVM_DRIVER, MODULE, COVERGROUP, ...]
emits_relations: [HAS_DRIVER, HAS_MONITOR, EXTENDS, ...]
executable: icarium-indexer-codebert
```

The built-in extractor (`icarium-indexer-codebert`) runs a fine-tuned
GraphCodeBERT model (125M parameters, MIT licence) for SV/UVM named-entity
recognition. Model files live in `$ICARIUM_MODELS` or the path set in
`icarium.toml`.

**Model performance** (epoch 5, 6,257-file corpus):
F1 = 0.972 · Precision = 0.969 · Recall = 0.975 · Accuracy = 0.995

### Capability plugins

In-process method handlers registered at startup. The kanban plugin ships
built-in.

```yaml
name: icarium-kanban
kind: capability
provides_methods: [kanban.add, kanban.list, kanban.get, kanban.update,
                   kanban.move, kanban.link]
provides_hooks:   [on_task_complete, on_finding]
```

### Plugin discovery

Daemon scans at startup:
1. `$ICARIUM_BIN/../plugins/<name>/plugin.yaml` (built-in)
2. `~/.icarium/plugins/<name>/plugin.yaml` (user)
3. `./.icarium/plugins/<name>/plugin.yaml` (project, requires `ICARIUM_ENABLE_PROJECT_PLUGINS=1`)

### Hook system

Hooks are fire-and-forget notifications fired on daemon events:

| Hook | Fires when |
|---|---|
| `pre_index` | Before plugin_runner starts on a file batch |
| `post_index` | After plugin_runner completes |
| `on_task_complete` | A task queue entry reaches `done` or `failed` |
| `on_finding` | A triage gear writes a finding |
| `on_gear_stage_complete` | A gear executor stage finishes |
| `on_gear_complete` | A gear run reaches its termination condition |

---

## Gears (Pipeline Definitions)

Gears are YAML-like pipeline definitions that describe multi-step DV tasks.
The daemon loads them at startup from (in priority order):

1. `ICARIUM_GEARS` env var directory
2. `./gears/` alongside the binary
3. `~/.icarium/gears/`

### Format

```yaml
name: close_coverage
version: 1

triggers:
  - "close coverage"
  - "close_coverage"
  - "coverage closure"

stages:
  - id: decompose
    type: llm
  - id: execute
    type: process
  - id: analyze
    type: llm
  - id: analyze_gaps
    type: parallel_llm
  - id: synthesize
    type: llm

termination:
  condition: synthesize.status == done
  max_iterations: 10
  on_max: return_last_synthesize
```

Stage types: `llm` `process` `parallel_llm` `condition`

### Built-in gears

| Gear | Triggers | Description |
|---|---|---|
| `close_coverage` | "close coverage", "coverage closure" | Decompose → simulate → analyze gaps (parallel) → synthesize |
| `triage` | "triage", "failures", "regression triage" | Parse failure logs → cluster → root-cause per cluster → synthesize |
| `simulate` | "simulate", "run sim", "smoke test" | Build run command → launch subprocess → parse pass/fail |
| `debug` | "debug", "why is", "investigate" | Gather context → 3 hypotheses → verify each → rank |

---

## Planned Phases

| Phase | Goal | Status |
|---|---|---|
| 1 — Entity store queries | IPC query handlers against indexed entity/relation tables | ✓ Done |
| 2 — Gear format + parser | Load and validate gear definition files | ✓ Done |
| 2B — Plugin infrastructure | Plugin manifests, hooks, kanban plugin | ✓ Done |
| 3 — LLM pool | Parallel structured LLM calls (Anthropic + OpenAI-compat) | Next |
| 4 — Gear executor | Run a gear end-to-end: stage loop, template fill, iteration | Next |
| 5 — Router | Natural language → gear selection (trigger match → embedding → LLM) | |
| 6 — Built-in gears | Full prompt templates and output schemas for all four gears | |
| 7 — Relation extraction | Heuristic SV relation extractor (EXTENDS, HAS_DRIVER, DRIVES…) | |
| 8 — pgvector embeddings | Semantic entity search via HNSW index | |
| 9 — TUI | Interactive REPL + live task queue + findings panes | |
| 10 — Hardening | Docs, `icariumd doctor`, config validation, structured errors | |

### Phase 3 — LLM Pool (next)

`src/zig/llm.zig` — two backends (Anthropic native tool_use, OpenAI-compatible
json_schema), parallel call support via thread pool, structured JSON output
enforced by schema. Done when two parallel LLM calls return valid JSON against
a test schema.

### Phase 4 — Gear Executor (next, parallel with Phase 3)

`src/zig/executor.zig` — the core iteration loop. Runs each gear stage in order,
template-fills `{stage.field}` references from prior outputs, handles
`continue`/`done` termination conditions, enforces `max_iterations`. Done when
`close_coverage` runs end-to-end with a stubbed LLM echo server.

### Phase 5 — Router

`src/zig/router.zig` — three-tier matching: exact trigger substring → embedding
cosine similarity → LLM fallback. Pure structural queries (`"list all UVM agents"`)
bypass gear selection and go directly to the entity store.

---

## Development Notes

**Single-threaded IPC loop**: `ipc.zig` uses module-level `g_resp_buf` and
`g_data_buf` instead of stack buffers. Returning slices into stack-allocated
arrays from `dispatch()` is UB; the module-level buffers are safe because the
accept loop handles one connection at a time.

**Gear parser**: line-oriented indent state machine in `gear.zig`. Indent 0 =
top-level scalars/section headers; indent 2 = list items; indent 4 = object
fields within list items. All strings are arena-allocated; call `gear.deinit()`
to free.

**Optional SQL filters**: nullable query parameters use PostgreSQL's
`$N::text IS NULL OR col = $N` pattern. When libpq passes a C NULL pointer for
a params-array entry, `$N` becomes SQL NULL, the `IS NULL` branch is TRUE, and
the filter is skipped entirely.

**In-process capability plugins**: `plugins/kanban.zig` is linked directly into
the daemon rather than running as a sidecar process. The external-process
protocol (Unix socket NDJSON with `{"ready":true,"socket":"..."}` handshake)
is planned for Phase 10.

---

## Licence

Source available. See LICENCE file.
