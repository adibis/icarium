#!/bin/sh
# Fails unless every pin needed by an implemented phase resolves exactly.
# Future pins are reported, never enforced: enforcement grows with phases.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "check-pins: $1" >&2; exit 1; }

command -v zig >/dev/null 2>&1 || fail "zig not on PATH"

pinned_zig=$(sed -n 's/^  "zig_version": "\(.*\)",$/\1/p' pins.json)
[ -n "$pinned_zig" ] || fail "cannot read zig_version from pins.json"
[ "$(zig version)" = "$pinned_zig" ] || fail "zig is $(zig version), pins.json wants $pinned_zig"

implemented=$(sed -n 's/^  "implemented_through_phase": \([0-9]*\),$/\1/p' pins.json)
[ -n "$implemented" ] || fail "cannot read implemented_through_phase from pins.json"

# Heredoc, not a pipe: fail() must exit this shell, not a subshell.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(echo "$line" | sed -n 's/^    "\([^"]*\)".*/\1/p')
    needed=$(echo "$line" | sed -n 's/.*"needed_by_phase": \([0-9]*\).*/\1/p')
    if [ "$needed" -le "$implemented" ]; then
        echo "$line" | grep -q '"version": null' && fail "$name needed by phase $needed but unresolved"
        case "$name" in
            yosys) command -v yosys >/dev/null 2>&1 || fail "yosys not on PATH" ;;
            *) fail "no verifier for applicable pin $name" ;;
        esac
        echo "check-pins: $name ok"
    else
        echo "check-pins: $name deferred (needed by phase $needed)"
    fi
done <<EOF
$(grep '"needed_by_phase"' pins.json)
EOF

# CI must install whatever pins.json says, not a second hardcoded copy.
grep -q 'steps.pins.outputs.zig' .github/workflows/ci.yml || fail "ci.yml does not read zig from pins.json"
grep -q 'zig_version' .github/workflows/ci.yml || fail "ci.yml does not read zig_version from pins.json"
echo "check-pins: zig $pinned_zig ok, ci.yml reads pins.json"
