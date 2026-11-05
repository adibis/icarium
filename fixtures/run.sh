#!/bin/sh
# Rule fixture suite: elaborate every fixtures/<RULE>/*.sv, run
# icarium check, compare rule-ID sets against manifest.json.
# Rule dirs enumerate from the registry: a rule without a dir, a
# file without a manifest entry, or an entry without a file fails.
# Exit: 0 all pass, 1 mismatch, 3 yosys or binary missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ICARIUM_BIN:-$ROOT/zig-out/bin/icarium}"
[ -x "$BIN" ] || { echo "fixtures: build first (zig build): $BIN missing" >&2; exit 3; }
command -v yosys >/dev/null 2>&1 || { echo "fixtures: SKIP, yosys not on PATH" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "fixtures: SKIP, python3 not on PATH" >&2; exit 3; }

case "$BIN" in
    /*) ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$ROOT" || exit 3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ran=0

expect_ids() {
    # expect_ids <manifest> <file>: sorted rule-ID set, one per line.
    python3 -c 'import json,sys; ids=sorted(json.load(open(sys.argv[1]))[sys.argv[2]]); sys.stdout.write("\n".join(ids) + ("\n" if ids else ""))' "$1" "$2"
}

for rule in $("$BIN" rules --list); do
    dir="fixtures/$rule"
    [ -d "$dir" ] || { echo "FAIL $rule: missing $dir"; fail=1; continue; }
    [ -f "$dir/manifest.json" ] || { echo "FAIL $rule: missing manifest.json"; fail=1; continue; }
    for sv in "$dir"/*.sv; do
        [ -f "$sv" ] || continue
        base="$(basename "$sv")"
        top="${base%.sv}"
        ran=$((ran + 1))
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))[sys.argv[2]]' \
            "$dir/manifest.json" "$base" >/dev/null 2>&1; then
            echo "FAIL $rule/$base: no manifest entry"
            fail=1
            continue
        fi
        if ! sh scripts/elaborate.sh --top "$top" --out "$TMP/$rule-$top.json" \
            "$sv" >"$TMP/$rule-$top.elab.log" 2>&1; then
            echo "FAIL $rule/$base: elaboration failed"
            fail=1
            continue
        fi
        sdc=""
        [ -f "$dir/$top.sdc" ] && sdc="--sdc $dir/$top.sdc"
        set +e
        # shellcheck disable=SC2086
        "$BIN" check --yosys-json "$TMP/$rule-$top.json" $sdc --format ids \
            >"$TMP/$rule-$top.ids1" 2>"$TMP/$rule-$top.err"
        code=$?
        # shellcheck disable=SC2086
        "$BIN" check --yosys-json "$TMP/$rule-$top.json" $sdc --format ids \
            >"$TMP/$rule-$top.ids2" 2>/dev/null
        code2=$?
        set -e
        if [ $code -ge 2 ] || [ $code2 -ge 2 ]; then
            echo "FAIL $rule/$base: check errored"
            fail=1
            continue
        fi
        if ! cmp -s "$TMP/$rule-$top.ids1" "$TMP/$rule-$top.ids2"; then
            echo "FAIL $rule/$base: nondeterministic output"
            fail=1
            continue
        fi
        grep -v '^$' "$TMP/$rule-$top.ids1" | sort -u >"$TMP/$rule-$top.got"
        expect_ids "$dir/manifest.json" "$base" >"$TMP/$rule-$top.want"
        if cmp -s "$TMP/$rule-$top.got" "$TMP/$rule-$top.want"; then
            echo "PASS $rule/$base"
        else
            echo "FAIL $rule/$base: want [$(tr '\n' ' ' <"$TMP/$rule-$top.want")] got [$(tr '\n' ' ' <"$TMP/$rule-$top.got")]"
            fail=1
        fi
    done
    python3 - "$dir/manifest.json" "$dir" <<'EOF'
import json, os, sys
man, d = sys.argv[1], sys.argv[2]
have = {f for f in os.listdir(d) if f.endswith(".sv")}
for f in sorted(set(json.load(open(man))) - have):
    print(f"FAIL {d}/{f}: manifest entry without a file")
    sys.exit(1)
EOF
    [ $? -eq 0 ] || fail=1
done

if [ "$ran" -eq 0 ]; then
    echo "fixtures: no fixture files found" >&2
    exit 1
fi
[ "$fail" -eq 0 ]
