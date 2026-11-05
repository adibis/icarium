#!/bin/sh
# Elaborate SystemVerilog to Yosys JSON for icarium ingestion.
# Usage: elaborate.sh --top TOP --out OUT.json [--frontend stock|slang] FILE...
# The slang read command varies by Yosys build; override via SLANG_READ_CMD.
set -eu

TOP=""; OUT=""; FRONTEND="stock"
FILES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --top) TOP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --frontend) FRONTEND="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "elaborate.sh: unknown flag $1" >&2; exit 2 ;;
        *) FILES="$FILES $1"; shift ;;
    esac
done
[ -n "$TOP" ] && [ -n "$OUT" ] && [ -n "$FILES" ] || {
    echo "usage: elaborate.sh --top TOP --out OUT.json [--frontend stock|slang] FILE..." >&2
    exit 2
}
command -v yosys >/dev/null 2>&1 || { echo "elaborate.sh: yosys not on PATH" >&2; exit 3; }

case "$FRONTEND" in
    stock) READ="read_verilog -sv" ;;
    slang) READ="${SLANG_READ_CMD:-read_slang}" ;;
    *) echo "elaborate.sh: frontend must be stock or slang" >&2; exit 2 ;;
esac

# Near-RTL structure only: no opt/techmap, so flops and muxes stay visible.
yosys -p "$READ $FILES; hierarchy -check -top $TOP; proc; flatten; write_json $OUT"
