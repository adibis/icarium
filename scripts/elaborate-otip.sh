#!/bin/sh
# Elaborate an OpenTitan IP to Yosys JSON via FuseSoC + slang.
# Usage: elaborate-otip.sh --core CORE --top TOP --out OUT.json
#        [--ot DIR] [--yosys BIN] [--prelude FILE]
# FuseSoC resolves the file list; technology prims swap to generic
# (ASIC cells have no RTL to analyze); read_slang elaborates.
# Needs: fusesoc (2.4.5 per OpenTitan's pin), yosys with read_slang.
# Exit: 0 ok, 1 elaborate failed, 2 bad usage, 3 missing tool.
set -eu

CORE=""; TOP=""; OUT=""; OT=""; YOSYS="${YOSYS:-yosys}"; PRELUDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        --top) TOP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --ot) OT="$2"; shift 2 ;;
        --yosys) YOSYS="$2"; shift 2 ;;
        --prelude) PRELUDE="$2"; shift 2 ;;
        -*) echo "elaborate-otip: unknown flag $1" >&2; exit 2 ;;
        *) echo "elaborate-otip: unexpected arg $1" >&2; exit 2 ;;
    esac
done
[ -n "$CORE" ] && [ -n "$TOP" ] && [ -n "$OUT" ] || {
    echo "usage: elaborate-otip.sh --core CORE --top TOP --out OUT.json [--ot DIR] [--yosys BIN] [--prelude FILE]" >&2
    exit 2
}
command -v fusesoc >/dev/null 2>&1 || { echo "elaborate-otip: fusesoc not on PATH" >&2; exit 3; }
command -v "$YOSYS" >/dev/null 2>&1 || { echo "elaborate-otip: $YOSYS not on PATH" >&2; exit 3; }
"$YOSYS" -p "help read_slang" 2>/dev/null | grep -q "read_slang \[" || {
    echo "elaborate-otip: $YOSYS lacks read_slang (need slang-capable yosys, e.g. OSS CAD Suite)" >&2
    exit 3
}
if [ -z "$OT" ]; then
    if [ -d "$HOME/opentitan" ]; then OT="$HOME/opentitan";
    else echo "elaborate-otip: pass --ot DIR (OpenTitan checkout)" >&2; exit 2; fi
fi

# FuseSoC file list via the verilator backend (setup only: no build).
BLD=$(mktemp -d)
trap 'rm -rf "$BLD"' EXIT INT TERM
(cd "$OT" && fusesoc --cores-root=. run --target=default --setup \
    --no-export --tool=verilator "$CORE" >/dev/null 2>&1) || {
    echo "elaborate-otip: fusesoc setup failed for $CORE" >&2; exit 1
}
VC=$(find "$OT/build" -name "*.vc" -path "*$(echo "$CORE" | tr ':' '_')*" | head -1)
[ -n "$VC" ] || { echo "elaborate-otip: no .vc emitted for $CORE" >&2; exit 1; }
VCDIR=$(dirname "$VC")
grep "\.sv$" "$VC" | grep -v "^+" | grep -v "prim_asap7" | sed "s|^|$VCDIR/|" > "$BLD/files.txt"
# Generic implementations for every tech-selected prim in the list.
grep "prim_asap7.*\.sv" "$VC" | sed 's|.*/||' | sort -u | while read -r base; do
    gen="$OT/hw/ip/prim_generic/rtl/$base"
    [ -f "$gen" ] && echo "$gen" >> "$BLD/files.txt"
done
if [ -n "$PRELUDE" ]; then
    { echo "$PRELUDE"; cat "$BLD/files.txt"; } > "$BLD/withpre.txt"
    mv "$BLD/withpre.txt" "$BLD/files.txt"
fi
# shellcheck disable=SC2046
"$YOSYS" -p "read_slang --single-unit -I$OT/hw/ip/prim/rtl -I$OT/hw/dv/sv/dv_utils --top $TOP $(cat "$BLD/files.txt" | tr '\n' ' '); hierarchy -check -top $TOP; proc; flatten; write_json $OUT" || {
    echo "elaborate-otip: yosys elaboration failed for $TOP" >&2; exit 1
}
echo "elaborate-otip: wrote $OUT"
