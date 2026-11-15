# Contributing to icarium

Thanks for using icarium. Contributions of every kind are welcome: bug reports,
fixes, new rules, test designs and documentation.

## Found a bug?

- Search the [issues](https://github.com/adibis/icarium/issues) first; it may
  already be reported.
- Try the latest `master`; it may already be fixed.
- Open an issue with a **small design that shows it**: a `.sv` file, the
  `.sdc` that goes with it, the exact commands you ran, the output you got and
  the output you expected. The ideal report is shaped like a case in
  `fixtures/` or [cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests), so
  it can land as a regression test.
- A wrong finding and a missing finding are both bugs. So is a finding that is
  right but hard to act on.

Designs you attach must be yours to share under an open license. Do not post
proprietary RTL.

## Sending a patch

- Open an issue first for anything larger than a small fix, so the approach
  can be agreed before you write it.
- One concern per pull request; small topic files over large rewrites.
- New behavior needs a fixture or e2e case, not just a unit test: the
  SystemVerilog suite is the contract. A fix lands with a test that failed
  before it.
- CI also runs every case of
  [cdc-rdc-tests](https://github.com/adibis/cdc-rdc-tests) at the commit
  `pins.json` names. A rule change that moves a suite verdict lands with the
  matching suite change, and the pin moves to that commit.
- Run the pre-commit check before every commit:

  ```sh
  sh scripts/precommit-check.sh staged
  ```

  It checks the diff and the commit message, and requires a green build, unit
  tests, e2e, fixtures, schemas and snapshots. CI runs the same gates.

### Commit messages

- No `feat:`/`fix:` prefixes; the subject names the change.
- No internal tracking IDs; write for a reader with no context.
- The body explains *why*, briefly; the diff shows the what.

### Code

- Zig 0.17, `zig fmt` clean, no warnings.
- Small topic files; tests mirror `src` under `tests/`.
<!-- REUSE-IgnoreStart -->
- Every source file starts with `// SPDX-License-Identifier: Apache-2.0`.
<!-- REUSE-IgnoreEnd -->
- Comments explain *why*, never the obvious *what*. Keep inline comments
  short; file and contract headers may run longer when the contract needs it.

### Docs

Rule pages and the CLI reference are generated. Edit the generator inputs,
then re-run:

```sh
python3 site/scripts/gen-rules.py
python3 site/scripts/gen-cli.py
```

Prose pages are hand-written; verify every claim against the code before
committing.

## Certifying your contribution

Contributions must be certified as open source under the
[Developer Certificate of Origin](https://developercertificate.org/) (DCO).
On your first contribution, add your name to [CONTRIBUTORS](CONTRIBUTORS) in
the same pull request. That certifies this and all your future contributions.
Your name must match the author name on your commits; CI checks it.

If you would rather not have your name published, say so in an issue and
certify privately; the maintainer will arrange it.

Contributions are licensed under the Apache License 2.0 ([LICENSE](LICENSE)).
There is no separate contributor agreement.

## AI policy

AI tools may help you write a contribution; they may not submit one. A human
is in the loop on every issue, pull request and commit, and is responsible
for reviewing, testing and understanding everything they submit. By signing
CONTRIBUTORS you certify that generated content is effectively your own work,
meets the project's standards, and that you can answer questions about it.

- Disclose significant AI assistance in the pull request description.
- Make sure the tool's terms put no restriction on its output that conflicts
  with Apache-2.0.
- Third-party material in a tool's output needs the same license check as
  material you copied yourself.

## Questions

Ask in the [issues](https://github.com/adibis/icarium/issues). Read the
[documentation](https://adibis.github.io/icarium/) first; a question it
should have answered is a documentation bug.

## Code of conduct

Participants pledge to make taking part in this project a positive experience
for everyone. icarium follows the
[Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
Report conduct concerns privately to the maintainer (adibis on GitHub).
