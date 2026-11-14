---
title: Contributing
weight: 64
---

## Before every commit

```sh
sh scripts/precommit-check.sh staged
```

It checks the diff and the commit message, and requires
green build, unit tests, e2e, fixtures, schemas, and
snapshots.

## Commit messages

- No `feat:`/`fix:` prefixes; the subject names the change.
- No internal tracking IDs; write for an external reader.
- Body explains *why*, briefly; the diff shows the what.

## Code

- Small topic files; tests mirror `src` under `tests/`.
- Comments explain *why*, never the obvious *what*. Keep
  inline comments short; file and contract headers may run
  longer when the contract needs it.
- Zig 0.17, `zig fmt` clean, no warnings.
- New behavior needs a fixture or e2e case, not just a unit
  test: the SystemVerilog suite is the contract.

## Docs

Rule pages and the CLI reference are generated — edit the
generator inputs (`icarium rules --doc`, `fixtures/`,
`tests/snapshots/help.txt`), then re-run:

```sh
python3 site/scripts/gen-rules.py
python3 site/scripts/gen-cli.py
```

Prose pages are hand-written; verify every claim against the
code before committing.
