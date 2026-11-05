#!/bin/sh
# Suppression suite: waiver/pragma/baseline/hints/scan behavior at
# the CLI level. Each tests/suppress/cases/<name>/ holds design.txt
# (sv + sdc paths, optional third line naming top when it differs
# from the file stem), optional waivers.json and flags.txt (extra
# check args, one per line), and expect.json ({exit, kept, waived,
# unmatched} rule-ID sets). Exit: 0 all pass, 1 mismatch, 3 yosys,
# binary, python3, or jsonschema missing.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${ICARIUM_BIN:-$ROOT/zig-out/bin/icarium}"
[ -x "$BIN" ] || { echo "suppress: build first (zig build): $BIN missing" >&2; exit 3; }
command -v yosys >/dev/null 2>&1 || { echo "suppress: SKIP, yosys not on PATH" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "suppress: SKIP, python3 not on PATH" >&2; exit 3; }
python3 -c "import jsonschema" 2>/dev/null || { echo "suppress: SKIP, python3 jsonschema missing" >&2; exit 3; }

case "$BIN" in
    /*) ;;
    *) BIN="$(pwd)/$BIN" ;;
esac
cd "$ROOT" || exit 3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ran=0

for case in tests/suppress/cases/*/; do
    name="$(basename "$case")"
    sv="$(sed -n '1p' "$case/design.txt")"
    sdc="$(sed -n '2p' "$case/design.txt")"
    top="$(sed -n '3p' "$case/design.txt")"
    [ -n "$top" ] || top="$(basename "$sv" .sv)"
    sh scripts/elaborate.sh --top "$top" --out "$TMP/net.json" "$sv" >/dev/null 2>&1
    flags=""
    [ -f "$case/flags.txt" ] && flags="$(tr '\n' ' ' < "$case/flags.txt")"
    if [ -f "$case/waivers.json" ]; then
        python3 -c "import json,jsonschema; jsonschema.validate(json.load(open('$case/waivers.json')), json.load(open('schema/waivers-1.0.json')))" 2>"$TMP/serr.txt" || { echo "FAIL $name: waivers.json violates schema"; cat "$TMP/serr.txt"; fail=1; continue; }
    fi
    # shellcheck disable=SC2086
    extra=""
    if [ -f "$case/waivers.json" ]; then extra="$extra --waivers $case/waivers.json"; fi
    if [ -f "$case/baseline.json" ]; then extra="$extra --baseline $case/baseline.json"; fi
    set +e
    "$BIN" check --yosys-json "$TMP/net.json" --sdc "$sdc" --format json $flags $extra > "$TMP/out.json" 2>"$TMP/stderr.txt"
    code=$?
    set -e
    ran=$((ran + 1))
    if python3 - "$case/expect.json" "$TMP/out.json" "$code" <<'EOF' >"$TMP/cmp.txt" 2>&1; then
import json, sys
exp = json.load(open(sys.argv[1]))
got = json.load(open(sys.argv[2]))
code = int(sys.argv[3])
kept, waived = [], []
for g in got["groups"]:
    for it in g["items"]:
        (waived if it["waiver"] else kept).append(g["rule"])
ok = (sorted(kept) == sorted(exp["kept"]) and sorted(waived) == sorted(exp.get("waived", []))
      and sorted(got["unmatched_waivers"]) == sorted(exp.get("unmatched", []))
      and got["summary"]["carried_over"] == exp.get("carried", 0) and code == exp["exit"])
if not ok:
    print(f"expected exit={exp['exit']} kept={sorted(exp['kept'])} waived={sorted(exp.get('waived', []))} unmatched={sorted(exp.get('unmatched', []))} carried={exp.get('carried', 0)}")
    print(f"got      exit={code} kept={sorted(kept)} waived={sorted(waived)} unmatched={sorted(got['unmatched_waivers'])} carried={got['summary']['carried_over']}")
    sys.exit(1)
EOF
        echo "PASS $name"
    else
        echo "FAIL $name"
        cat "$TMP/cmp.txt" | sed 's/^/    /'
        fail=1
    fi
done

[ "$ran" -gt 0 ] || { echo "FAIL suppress: no cases found" >&2; exit 1; }
exit "$fail"
