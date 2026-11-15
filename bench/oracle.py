#!/usr/bin/env python3
"""Build the waiver oracle: every OpenTitan Meridian waiver as one
recall record, mapped through the signed rule map.

The oracle is the benchmark the recall gate measures against: each
entry names the Meridian rule, the mapped icarium rules, and the
endpoints Meridian waived. Scope splits entries measurable today
(block netlists we elaborate) from chip-level ones waiting on a
full EarlGrey run, so unmeasurable entries never dilute recall.

Usage: python3 bench/oracle.py [--ot DIR] [--out FILE]
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OT = os.environ.get("OTIP", "")
CDC = "hw/top_earlgrey/cdc"

BLOCK_FILES = {"uart", "spi_device", "alert_handler", "gpio", "lc_ctrl"}


def need_ot(ot, who):
    # No default checkout location: the path is the caller's to give.
    if not ot:
        sys.exit(f"{who}: needs an OpenTitan checkout via --ot DIR or OTIP")
    return ot


def main():
    ot, out = OT, os.path.join(ROOT, "bench", "waiver_oracle.json")
    args = sys.argv[1:]
    while args:
        if args[0] == "--ot":
            ot, args = args[1], args[2:]
        elif args[0] == "--out":
            out, args = args[1], args[2:]
        else:
            sys.exit(f"oracle: unknown flag {args[0]}")
    binary = os.path.join(ROOT, "zig-out", "bin", "icarium")
    cdc = os.path.join(need_ot(ot, "oracle"), CDC)
    if not os.path.isdir(cdc):
        sys.exit(f"oracle: no cdc dir at {cdc}")
    pins = json.load(open(os.path.join(ROOT, "pins.json")))
    entries, failures = [], []
    files = sorted(f for f in os.listdir(cdc)
                   if f.startswith("cdc_waivers.") and f.endswith(".tcl")
                   and f != "cdc_waivers.tcl")
    for f in files:
        stem = f[len("cdc_waivers."):-len(".tcl")]
        scope = {"scope": "block", "block": stem} if stem in BLOCK_FILES \
            else {"scope": "chip"}
        tmp = os.path.join("/tmp", f"oracle-{stem}.json")
        r = subprocess.run([binary, "import-meridian",
                            "--in", os.path.join(cdc, f),
                            "--map", os.path.join(ROOT, "bench",
                                                 "meridian_map.json"),
                            "--out", tmp],
                           capture_output=True, text=True)
        if r.returncode not in (0, 1) or not os.path.exists(tmp):
            failures.append({"file": f, "error": r.stderr.strip()[-300:]})
            continue
        for w in json.load(open(tmp))["waivers"]:
            reason = w.get("reason", "")
            rule = reason[1:reason.index("]")] if reason.startswith("[") \
                and "]" in reason else "?"
            entries.append({
                "id": f"{stem}:{w['id']}",
                "file": f, **scope,
                "meridian_rule": rule,
                "icarium_rules": w["rules"],
                "driver": w.get("driver"), "dst": w.get("dst"),
                "comment": reason,
            })
        os.unlink(tmp)
    entries.sort(key=lambda e: (e["file"], e["id"]))
    oracle = {"meta": {
        "opentitan": pins["tools"]["opentitan"]["commit"],
        "map": "bench/meridian_map.json (signed)",
        "files": len(files), "failures": failures,
    }, "entries": entries}
    json.dump(oracle, open(out, "w"), indent=1)
    n_block = sum(1 for e in entries if e["scope"] == "block")
    print(f"oracle: {len(entries)} entries "
          f"({n_block} block, {len(entries) - n_block} chip), "
          f"{len(failures)} file failures -> {out}")


if __name__ == "__main__":
    main()
