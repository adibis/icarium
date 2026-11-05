#!/bin/sh
# TOON size proof: TOON findings must stay smaller than minified
# JSON on every representative case, and must round-trip through
# the reference decoder where it is installed. Exit: 0 proof
# holds, 1 TOON not smaller or round-trip mismatch, 3 yosys or
# the binary missing. Token counts via tiktoken are reported
# when installed, never gated.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ICARIUM_BIN:-$ROOT/zig-out/bin/icarium}"
[ -x "$BIN" ] || { echo "toon-tokens: build first (zig build): $BIN missing" >&2; exit 3; }
command -v yosys >/dev/null 2>&1 || { echo "toon-tokens: SKIP, yosys not on PATH" >&2; exit 3; }
cd "$ROOT" || exit 3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check_one() {
    # check_one <sv> <sdc> <label>
    sv="$1"; sdc="$2"; label="$3"
    top="$(basename "$sv" .sv)"
    case "$label" in
        scan-4) top="scan_ignored" ;;
    esac
    sh scripts/elaborate.sh --top "$top" --out "$TMP/net.json" "$sv" >/dev/null 2>&1
    "$BIN" check --yosys-json "$TMP/net.json" --sdc "$sdc" --format json --minify > "$TMP/out.json" 2>/dev/null || true
    "$BIN" check --yosys-json "$TMP/net.json" --sdc "$sdc" --format toon > "$TMP/out.toon" 2>/dev/null || true
    jb=$(wc -c < "$TMP/out.json" | tr -d ' ')
    tb=$(wc -c < "$TMP/out.toon" | tr -d ' ')
    if [ "$tb" -ge "$jb" ]; then
        echo "FAIL $label: toon $tb bytes >= minified json $jb bytes"
        fail=1
        return
    fi
    echo "PASS $label: toon $tb bytes < minified json $jb bytes"
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import toon_format" 2>/dev/null; then
            python3 - "$TMP/out.json" "$TMP/out.toon" <<'EOF' || fail=1
import json, sys
js = json.load(open(sys.argv[1]))
import toon_format
rows = toon_format.decode(open(sys.argv[2]).read())
items = [(g["rule"], it["dst"]["name"], it["message"]) for g in js["groups"] for it in g["items"]]
got = [(r["rule"], r["dst"], r["message"]) for r in rows]
assert len(items) == len(got), (len(items), len(got))
assert sorted(items) == sorted(got), "row content differs"
print("  reference round-trip ok:", len(got), "rows")
EOF
        else
            echo "  (reference decoder not installed, skipped)"
        fi
        if python3 -c "import tiktoken" 2>/dev/null; then
            python3 - "$TMP/out.json" "$TMP/out.toon" <<'EOF'
import sys
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")
jb = open(sys.argv[1], "rb").read().decode()
tb = open(sys.argv[2], "rb").read().decode()
print(f"  tokens: toon {len(enc.encode(tb))} < json {len(enc.encode(jb))}")
EOF
        fi
    fi
}

check_one fixtures/RDC-008/bad_reset_port_missed_domain.sv fixtures/RDC-008/bad_reset_port_missed_domain.sdc "grouped-1"
check_one fixtures/RDC-003/bad_sync_reset_crossing.sv fixtures/RDC-003/bad_sync_reset_crossing.sdc "two-rule-2"
check_one tests/suppress/cases/scan-ignored/design.sv tests/suppress/cases/scan-ignored/design.sdc "scan-4"

exit "$fail"
