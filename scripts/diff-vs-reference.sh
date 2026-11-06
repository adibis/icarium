#!/bin/sh
# Differential: icarium crossings vs rtl-buddy-cdc domain maps.
# Manual dev tool, not a CI gate: needs rtl-buddy-cdc on PATH and
# elaborates every e2e case twice. Skips quietly without the tool.
set -u

command -v rtl-buddy-cdc >/dev/null 2>&1 || {
    echo "diff-vs-reference: SKIP (rtl-buddy-cdc not on PATH)"; exit 0
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=$ROOT/zig-out/bin/icarium
[ -x "$BIN" ] || { echo "diff-vs-reference: run zig build first"; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM

for sv in "$ROOT"/tests/e2e/*/design.sv; do
    case=$(basename "$(dirname "$sv")")
    sh "$ROOT/scripts/elaborate.sh" --top "$case" \
        --out "$TMPD/$case.json" "$sv" >/dev/null 2>&1 || {
        echo "diff-vs-reference: elaborate failed for $case"; exit 1
    }
    # Exit 1 means findings, not failure; the map is still emitted.
    rtl-buddy-cdc analyze --netlist "$TMPD/$case.json" \
        --sdc "$ROOT/tests/e2e/$case/constraints.sdc" \
        --emit-domain-map "$TMPD/ref-$case.json" >/dev/null 2>&1 || true
done

python3 - "$ROOT" "$TMPD" <<'EOF'
import json, re, sys
root, tmpd = sys.argv[1], sys.argv[2]
fails = []

def parse_ours(case):
    recs = []
    for line in open(f"{root}/tests/e2e/{case}/expected.crossings"):
        m = re.match(r"crossing \S+ (\S+) (\S+) (\S+) (\S+) (\S+) async (\S+)", line)
        if m:
            k, s, d, sc, dc, a = m.groups()
            recs.append((k, s, d, sc, dc, a == "true"))
    return recs

def end(ep):
    p = ep.split(":")
    return ("port", p[1], "") if p[0] == "p" else ("cell", ":".join(p[1:-2]), p[-2])

def strip(top, name):
    return name[len(top) + 1:] if name.startswith(top + ".") else name

import glob, os
for sv in sorted(glob.glob(f"{root}/tests/e2e/*/design.sv")):
    case = os.path.basename(os.path.dirname(sv))
    ours = parse_ours(case)
    ref = json.load(open(f"{tmpd}/ref-{case}.json"))
    odom = dict(re.findall(r"flop (\S+) domain (\S+)",
                           open(f"{root}/tests/e2e/{case}/expected.domains").read()))
    for f in ref["flop_domains"]:
        c, want = strip(case, f["instance_path"]), odom.get(strip(case, f["instance_path"]))
        # D1: muxed clocks union here, first-wins there. Deliberate.
        if f["clock"] != want and (case, c) != ("mux_clock", "$procdff$3"):
            fails.append(f"{case}: domain {c} ref={f['clock']} ours={want}")
    op, rp = {}, {}
    for k, s, d, sc, dc, a in ours:
        if k in ("flop_flop_bit", "port_flop", "port_flop_untyped"):
            op.setdefault((end(s)[1], end(d)[1]), []).append((k, s, d, sc, dc, a))
    for x in ref["crossings"]:
        s = x.get("src_flop") or x.get("src_port") or x.get("src_boundary_pin")
        rp.setdefault((strip(case, s), strip(case, x["dst_flop"])), []).append(x)
    for k in sorted(set(rp) - set(op)):
        fails.append(f"{case}: REF-ONLY pair {k}")
    for k in sorted(set(op) - set(rp)):
        for _, s, d, _, _, a in op[k]:
            sk, sn, _ = end(s)
            dk, dn, dpin = end(d)
            mem = "mem" in sn or "mem" in dn
            if not (a is False or dpin in ("ARST", "SRST") or mem):
                fails.append(f"{case}: unexplained OURS-ONLY {k} {s}->{d}")
    for k in sorted(set(op) & set(rp)):
        if sorted({a for *_, a in op[k]}) != [rp[k][0]["async_per_sdc"]]:
            fails.append(f"{case}: ASYNC-DIVERGE {k}")

if fails:
    print("diff-vs-reference: FAIL")
    print("\n".join("  " + f for f in fails))
    sys.exit(1)
print("diff-vs-reference: match (modulo D1: muxed-clock union)")
EOF
