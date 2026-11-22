#!/bin/sh
# SystemVerilog end-to-end suite: elaborate each case with Yosys,
# run icarium over it, diff against hand-written goldens.
# Case layout: tests/e2e/<top>/design.sv, constraints.sdc (optional),
# expected.stats, expected.clocks (with constraints.sdc),
# expected.domains / expected.resets / expected.crossings (optional;
# --sdc passed when present).
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
    if [ -f "$case/expected.crossings" ]; then
        set -- "$BIN" crossings --yosys-json "$TMP/$name.json"
        if [ -f "$case/constraints.sdc" ]; then set -- "$@" --sdc "$case/constraints.sdc"; fi
        if ! "$@" >"$TMP/$name.crossings" 2>"$TMP/$name.crossings.err"; then
            echo "FAIL $name: crossings exited $?"
            cat "$TMP/$name.crossings.err"
            fail=1
            continue
        fi
        check "$name" crossings "$case/expected.crossings" "$TMP/$name.crossings"
    fi
done

# One-command check: RTL in must give exactly what the two-step
# elaborate-then-check flow gives.
for casedir in tests/e2e/*/; do
    name="$(basename "$casedir")"
    case="tests/e2e/$name"
    [ -f "$case/design.sv" ] && [ -f "$TMP/$name.json" ] || continue
    set -- --top "$name" --format json
    if [ -f "$case/constraints.sdc" ]; then set -- "$@" --sdc "$case/constraints.sdc"; fi
    "$BIN" check "$@" --yosys-json "$TMP/$name.json" >"$TMP/$name.two" 2>/dev/null || true
    "$BIN" check "$@" "$case/design.sv" >"$TMP/$name.one" 2>/dev/null || true
    check "$name" "check from RTL" "$TMP/$name.two" "$TMP/$name.one"
done

# expect <label> <code> <stderr pattern> -- <check args>: exit code and
# the message a user sees.
expect() {
    label="$1"; want="$2"; pat="$3"; shift 4
    code=0
    "$BIN" check "$@" >"$TMP/x.out" 2>"$TMP/x.err" || code=$?
    if [ "$code" -eq "$want" ] && grep -q -- "$pat" "$TMP/x.err"; then
        echo "PASS check $label"
    else
        echo "FAIL check $label: exit $code, want $want and /$pat/"
        cat "$TMP/x.err"
        fail=1
    fi
}

# A path with a space, an include directory and a define all reach Yosys:
# the crossing exists only when the define is set, and its width only
# when the include is found.
src="$TMP/rtl dir"
mkdir -p "$src" "$TMP/inc"
printf '`define W 1\n' >"$TMP/inc/w.svh"
cat >"$src/def top.sv" <<'SV'
`include "w.svh"
module def_top (input logic ca, input logic cb, input logic [`W-1:0] d, output logic [`W-1:0] q);
  logic [`W-1:0] a, b;
  always_ff @(posedge ca) a <= d;
`ifdef BAD
  always_ff @(posedge cb) b <= a;
`else
  always_ff @(posedge ca) b <= a;
`endif
  assign q = b;
endmodule
SV
printf 'create_clock -name ca -period 10 [get_ports ca]\ncreate_clock -name cb -period 7 [get_ports cb]\nset_clock_groups -asynchronous -group {ca} -group {cb}\nset_input_delay -clock ca 1 [get_ports d]\n' >"$src/c.sdc"
code=0
"$BIN" check --sdc "$src/c.sdc" -I "$TMP/inc" -DBAD --only CDC-001 --format ids "$src/def top.sv" >"$TMP/def.on" 2>"$TMP/def.err" || code=$?
"$BIN" check --sdc "$src/c.sdc" -I "$TMP/inc" --only CDC-001 --format ids "$src/def top.sv" >"$TMP/def.off" 2>>"$TMP/def.err" || true
if [ "$code" -eq 1 ] && [ "$(cat "$TMP/def.on")" = CDC-001 ] && [ ! -s "$TMP/def.off" ]; then
    echo "PASS check -I and -D reach Yosys"
else
    echo "FAIL check -I and -D reach Yosys: exit $code, on=[$(cat "$TMP/def.on")] off=[$(cat "$TMP/def.off")]"
    cat "$TMP/def.err"
    fail=1
fi

printf 'module broken(input a); assign = a; endmodule\n' >"$TMP/broken.sv"
expect "syntax error" 3 "elaboration failed" -- "$TMP/broken.sv"
expect "missing source" 3 "not found" -- "$TMP/nope.sv"
expect "unknown top" 3 "nosuch" -- --top nosuch "$src/def top.sv" -I "$TMP/inc"
expect "unsafe include" 2 "would misread include directory" -- -I "$src/inc dir" "$src/def top.sv"
expect "frontend with netlist" 2 "apply to RTL files" -- --frontend slang --yosys-json "$TMP/x.json"
expect "both inputs" 2 "not both" -- --yosys-json "$TMP/x.json" "$src/def top.sv"
expect "no input" 2 "no input" --
expect "typo" 2 "bad argument: --sdcc" -- --sdcc x "$src/def top.sv"
YOSYS=/nonexistent/yosys expect "no yosys" 3 "yosys not found" -- "$src/def top.sv"
if "$BIN" check --help | grep -q -- "--yosys-json FILE"; then
    echo "PASS check --help"
else
    echo "FAIL check --help"
    fail=1
fi

echo "e2e: $ran cases, $([ "$fail" -eq 0 ] && echo pass || echo FAIL)"
exit "$fail"
