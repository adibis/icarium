#!/bin/sh
# Schema validation: emit every native JSON artifact from a small
# representative netlist set and validate each against its schema
# in schema/. Exit: 0 all valid, 1 mismatch, 3 yosys, python3, or
# the jsonschema module missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ICARIUM_BIN:-$ROOT/zig-out/bin/icarium}"
[ -x "$BIN" ] || { echo "schemas: build first (zig build): $BIN missing" >&2; exit 3; }
command -v yosys >/dev/null 2>&1 || { echo "schemas: SKIP, yosys not on PATH" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "schemas: SKIP, python3 not on PATH" >&2; exit 3; }
python3 -c "import jsonschema" 2>/dev/null || { echo "schemas: SKIP, python3 jsonschema missing" >&2; exit 3; }

cd "$ROOT" || exit 3
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check_one() {
    # check_one <sv> <sdc> <format> <schema> <label>: elaborate, emit, validate.
    sv="$1"; sdc="$2"; fmt="$3"; schema="$4"; label="$5"
    top="$(basename "$sv" .sv)"
    sh scripts/elaborate.sh --top "$top" --out "$TMP/net.json" "$sv" >/dev/null 2>&1
    "$BIN" check --yosys-json "$TMP/net.json" --sdc "$sdc" --format "$fmt" > "$TMP/out.json" 2>/dev/null || true
    if python3 -c "import json,jsonschema,sys; jsonschema.validate(json.load(open('$TMP/out.json')), json.load(open('$schema')))" 2>"$TMP/err.txt"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        cat "$TMP/err.txt"
        fail=1
    fi
}

check_one fixtures/RDC-006/bad_muxed_reset_unsync.sv fixtures/RDC-006/bad_muxed_reset_unsync.sdc json schema/findings-1.0.json "findings/warning"
check_one fixtures/RDC-008/bad_reset_port_missed_domain.sv fixtures/RDC-008/bad_reset_port_missed_domain.sdc json schema/findings-1.0.json "findings/error-grouped"
check_one fixtures/RDC-008/good_reset_port_both_domains.sv fixtures/RDC-008/good_reset_port_both_domains.sdc json schema/findings-1.0.json "findings/empty"
check_one fixtures/RDC-006/bad_muxed_reset_unsync.sv fixtures/RDC-006/bad_muxed_reset_unsync.sdc sarif schema/sarif-2.1.0.json "sarif/warning"
check_one fixtures/RDC-008/bad_reset_port_missed_domain.sv fixtures/RDC-008/bad_reset_port_missed_domain.sdc sarif schema/sarif-2.1.0.json "sarif/error-grouped"
check_one fixtures/RDC-008/good_reset_port_both_domains.sv fixtures/RDC-008/good_reset_port_both_domains.sdc sarif schema/sarif-2.1.0.json "sarif/empty"

check_map() {
    # check_map <sv> <sdc> <flag> <schema> <label>: elaborate, emit map, validate.
    sv="$1"; sdc="$2"; flag="$3"; schema="$4"; label="$5"
    top="$(basename "$sv" .sv)"
    sh scripts/elaborate.sh --top "$top" --out "$TMP/net.json" "$sv" >/dev/null 2>&1
    "$BIN" check --yosys-json "$TMP/net.json" --sdc "$sdc" --format ids "$flag" "$TMP/out.json" >/dev/null 2>/dev/null || true
    if python3 -c "import json,jsonschema,sys; jsonschema.validate(json.load(open('$TMP/out.json')), json.load(open('$schema')))" 2>"$TMP/err.txt"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        cat "$TMP/err.txt"
        fail=1
    fi
}

check_map fixtures/RDC-008/bad_reset_port_missed_domain.sv fixtures/RDC-008/bad_reset_port_missed_domain.sdc --emit-domain-map schema/clock-map-1.0.json "clock-map/two-clock"
check_map fixtures/RDC-006/good_muxed_reset_synced.sv fixtures/RDC-006/good_muxed_reset_synced.sdc --emit-domain-map schema/clock-map-1.0.json "clock-map/synced-mux"

exit "$fail"
