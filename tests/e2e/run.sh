#!/bin/sh
# SystemVerilog end-to-end suite: elaborate each case with Yosys,
# run icarium over it, diff against hand-written goldens.
# Case layout: tests/e2e/<top>/design.sv, constraints.sdc (optional),
# expected.stats, expected.clocks (with constraints.sdc),
# expected.domains / expected.resets (optional; --sdc passed when
# present).
# Goldens were authored against Yosys 0.70 (stock frontend).
# Exit: 0 all pass, 1 golden mismatch, 3 yosys or binary missing.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${ICARIUM_BIN:-$ROOT/zig-out/bin/icarium}"
[ -x "$BIN" ] || { echo "e2e: build first (zig build): $BIN missing" >&2; exit 3; }
command -v yosys >/dev/null 2>&1 || { echo "e2e: SKIP, yosys not on PATH" >&2; exit 3; }

# Elaborate with repo-relative paths: Yosys embeds the file argument
# in generated cell names, and absolute paths would make goldens
# machine-specific. BIN is resolved first so a relative override
# survives the cd.
case "$BIN" in
    /*) ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$ROOT" || exit 3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ran=0

check() {
    # check <case> <label> <expected> <actual>: diff, count failures.
    if cmp -s "$3" "$4"; then
        echo "PASS $1 $2"
    else
        echo "FAIL $1 $2"
        diff -u "$3" "$4" || true
        fail=1
    fi
}

for casedir in tests/e2e/*/; do
    name="$(basename "$casedir")"
    case="tests/e2e/$name"
    [ -f "$case/design.sv" ] || continue
    ran=$((ran + 1))
    if ! sh "$ROOT/scripts/elaborate.sh" --top "$name" --out "$TMP/$name.json" \
        "$case/design.sv" >"$TMP/$name.elab.log" 2>&1; then
        echo "FAIL $name: elaboration failed"
        tail -5 "$TMP/$name.elab.log"
        fail=1
        continue
    fi
    if ! "$BIN" stats --yosys-json "$TMP/$name.json" >"$TMP/$name.stats" 2>"$TMP/$name.stats.err"; then
        echo "FAIL $name: stats exited $?"
        cat "$TMP/$name.stats.err"
        fail=1
        continue
    fi
    check "$name" stats "$case/expected.stats" "$TMP/$name.stats"
    if [ -f "$case/constraints.sdc" ]; then
        if ! "$BIN" clocks --sdc "$case/constraints.sdc" >"$TMP/$name.clocks" 2>"$TMP/$name.clocks.err"; then
            echo "FAIL $name: clocks exited $?"
            cat "$TMP/$name.clocks.err"
            fail=1
            continue
        fi
        check "$name" clocks "$case/expected.clocks" "$TMP/$name.clocks"
    fi
    if [ -f "$case/expected.domains" ]; then
        set -- "$BIN" domains --yosys-json "$TMP/$name.json"
        if [ -f "$case/constraints.sdc" ]; then set -- "$@" --sdc "$case/constraints.sdc"; fi
        if ! "$@" >"$TMP/$name.domains" 2>"$TMP/$name.domains.err"; then
            echo "FAIL $name: domains exited $?"
            cat "$TMP/$name.domains.err"
            fail=1
            continue
        fi
        check "$name" domains "$case/expected.domains" "$TMP/$name.domains"
    fi
    if [ -f "$case/expected.resets" ]; then
        set -- "$BIN" resets --yosys-json "$TMP/$name.json"
        if [ -f "$case/constraints.sdc" ]; then set -- "$@" --sdc "$case/constraints.sdc"; fi
        if ! "$@" >"$TMP/$name.resets" 2>"$TMP/$name.resets.err"; then
            echo "FAIL $name: resets exited $?"
            cat "$TMP/$name.resets.err"
            fail=1
            continue
        fi
        check "$name" resets "$case/expected.resets" "$TMP/$name.resets"
    fi
done

echo "e2e: $ran cases, $([ "$fail" -eq 0 ] && echo pass || echo FAIL)"
exit "$fail"
