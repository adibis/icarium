# Notes for AI agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first; its rules apply to you, including
the AI policy.

- A human reviews and submits everything. Draft issues and pull requests for
  your user to post; never open them yourself.
- Never edit `CONTRIBUTORS`. Only a human can certify a contribution.
- Build with `zig build`, test with `zig build test`. Before a commit, run
  `sh scripts/precommit-check.sh staged`; it needs Yosys on `PATH` for the
  end-to-end, fixture and schema suites.
- Every behavior change lands with a fixture or e2e case that failed before it.
  Don't change a golden output to make a test pass without explaining why the
  new output is correct.
- Rule pages and the CLI reference under `site/content/docs/` are generated;
  edit the generators in `site/scripts/`, not their output.
- Ground truth is the test designs and OpenTitan's waivers. Never use the
  output of a commercial CDC tool as a reference.
