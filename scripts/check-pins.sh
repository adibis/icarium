#!/bin/sh
# Fails unless the local Zig matches pins.json and CI installs what
# pins.json says rather than a second hardcoded copy.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "check-pins: $1" >&2; exit 1; }

command -v zig >/dev/null 2>&1 || fail "zig not on PATH"

pinned_zig=$(sed -n 's/^  "zig_version": "\(.*\)",$/\1/p' pins.json)
[ -n "$pinned_zig" ] || fail "cannot read zig_version from pins.json"
[ "$(zig version)" = "$pinned_zig" ] || fail "zig is $(zig version), pins.json wants $pinned_zig"

suite=$(sed -n 's/.*"cdc-rdc-tests": { "tag": "v[0-9.]*", "commit": "\([0-9a-f]\{40\}\)" }.*/\1/p' pins.json)
[ -n "$suite" ] || fail "cannot read the cdc-rdc-tests release tag and commit from pins.json"
suite_tag=$(sed -n 's/.*"cdc-rdc-tests": { "tag": "\(v[0-9.]*\)".*/\1/p' pins.json)

grep -q 'steps.pins.outputs.zig' .github/workflows/ci.yml || fail "ci.yml does not read zig from pins.json"
grep -q 'zig_version' .github/workflows/ci.yml || fail "ci.yml does not read zig_version from pins.json"
grep -q 'steps.pins.outputs.suite' .github/workflows/ci.yml || fail "ci.yml does not read the cdc-rdc-tests pin from pins.json"
grep -q 'steps.pins.outputs.suite_tag' .github/workflows/ci.yml || fail "ci.yml does not check the cdc-rdc-tests release tag"
echo "check-pins: zig $pinned_zig ok, cdc-rdc-tests $suite_tag at $suite, ci.yml reads pins.json"
