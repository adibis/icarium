#!/usr/bin/env python3
"""Recall gate: measure icarium findings against the waiver oracle.

For each elaborated block, every in-scope oracle entry gets a
verdict: full (rule plus both endpoints), partial (rule plus one
endpoint), rule-only, or missed. Entries naming only unimplemented
(reserved) rules and chip-scope entries without a netlist stay
pending, counted but never in the denominator. Extras never block:
recall counts what Meridian waived that we also flag.

Usage: python3 bench/recall.py [--ot DIR] [--yosys BIN] [--work DIR]
                             [--bless] [--enforce] [--baseline PATH]

--bless writes the blessed baseline (per-entry verdicts plus the
icarium commit) to the baseline path. --enforce exits 1 on any
miss, modeling gap, verdict downgrade, or dropped in-scope
entry versus the baseline. Finding counts never block: recall
measures what Meridian waived that we also flag, not volume.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from bench import TIER2, elaborate_tier2  # noqa: E402

STRIP = "*?{}\"' "
PREFIXES = ("top_earlgrey.u_spi_device.", "top_earlgrey.u_uart.",
            "top_earlgrey.", "u_spi_device.", "u_uart.", "$driver$")


def norm(s):
    if not s:
        return ""
    s = s.strip().strip(STRIP).lstrip(".")
    changed = True
    while changed:
        changed = False
        s = s.lstrip(".")
        for pre in PREFIXES:
            if s.startswith(pre):
                s = s[len(pre):].lstrip(".")
                changed = True
    s = s.split("[")[0]
    return s.strip().strip(STRIP).strip(".")


PINS = {"q", "q_o", "d", "clk", "rst", "rst_n", "arst", "srst", "en",
        "s", "a", "b", "y", "clk_i", "rst_ni"}


def variants(s):
    segs = [g for g in norm(s).split(".") if g]
    out = []
    if segs:
        out.append(".".join(segs))
    while segs and segs[-1].lower() in PINS:
        segs.pop()
        if segs:
            out.append(".".join(segs))
    return out


def rx(s):
    return re.compile(re.escape(s).replace(r"\*", ".*")
                      .replace(r"\?", "."))


def overlap(pattern, name):
    pv, nv = variants(pattern), variants(name)
    if not pv or not nv:
        return False
    for p in pv:
        rp = rx(p)
        for n in nv:
            if rp.search(n) or rx(n).search(p):
                return True
    return False


def check_block(binary, work, spec):
    name = spec["name"]
    js = os.path.join(work, f"t2-{name}.json")
    out = os.path.join(work, f"recall-{name}.findings.json")
    if not os.path.exists(js):
        return None, "no netlist (run bench tier2 or pass --work)"
    r = subprocess.run([binary, "check", "--yosys-json", js,
                        "--top", spec["top"],
                        "--sdc", os.path.join(ROOT, spec["sdc"]),
                        "--format", "json"],
                       capture_output=True, text=True)
    if r.returncode not in (0, 1):
        return None, f"check failed: {r.stderr.strip()[-200:]}"
    json.dump(json.loads(r.stdout), open(out, "w"))
    flat = []
    def ep(e):
        if isinstance(e, dict):
            return e.get("name", "")
        return str(e or "")

    for g in json.load(open(out))["groups"]:
        for it in g["items"]:
            flat.append({"rule": g["rule"],
                         "dst": ep(it.get("dst")),
                         "driver": ep(it.get("driver")),
                         "message": it.get("message", "")})
    return flat, None


def in_scope(entry, blob):
    given = [entry[k] for k in ("driver", "dst") if norm(entry[k])]
    if not given:
        return True
    for g in given:
        if not any(rx(v).search(blob) for v in variants(g)):
            return False
    return True


def verdict(entry, findings, blob):
    if not entry["driver"] and not entry["dst"]:
        return "pending-clock-model", None
    if blob is not None and not in_scope(entry, blob):
        return "pending-out-of-scope", None
    cands = [f for f in findings if f["rule"] in entry["icarium_rules"]]
    if not cands:
        for f in findings:
            if f["rule"] not in ("CDC-025", "CDC-011", "CDC-021"):
                continue
            if overlap(entry["driver"], f["driver"]) or \
               overlap(entry["driver"], f["dst"]) or \
               overlap(entry["dst"], f["dst"]) or \
               overlap(entry["dst"], f["driver"]):
                return "modeling-gap", f
        return "missed", None
    for f in cands:
        d = overlap(entry["driver"], f["driver"]) or \
            overlap(entry["driver"], f["dst"])
        r = overlap(entry["dst"], f["dst"]) or \
            overlap(entry["dst"], f["driver"])
        if d and r:
            return "full", f
    for f in cands:
        if overlap(entry["driver"], f["driver"]) or \
           overlap(entry["driver"], f["dst"]) or \
           overlap(entry["dst"], f["dst"]) or \
           overlap(entry["dst"], f["driver"]):
            return "partial", f
    return "rule-only", cands[0]


RANK = {"full": 3, "partial": 2, "rule-only": 1, "missed": 0,
        "modeling-gap": 0}


def compare(baseline, report):
    # Returns (ok, problems): absolute gates first (a miss or a
    # modeling gap fails even a first run), then per-entry
    # verdicts against the blessed ranks. Upgrades pass
    # silently; drops fail loudly so scope changes re-bless.
    problems = []
    for name, b in report["blocks"].items():
        if "error" in b:
            problems.append(f"{name}: {b['error']}")
            continue
        if b["missed"]:
            problems.append(f"{name}: {b['missed']} missed")
        if b["modeling-gap"]:
            problems.append(f"{name}: {b['modeling-gap']} modeling-gap")
    if baseline is None:
        return (not problems, problems)
    want = baseline["entries"]
    got = {e["id"]: e["verdict"] for e in report["entries"]}
    for i in sorted(set(want) - set(got)):
        problems.append(f"{i}: dropped from measurement "
                        f"(was {want[i]})")
    for i in sorted(set(got) - set(want)):
        if RANK[got[i]] == 0:
            problems.append(f"{i}: new entry {got[i]}")
    for i in sorted(set(want) & set(got)):
        if RANK[got[i]] < RANK[want[i]]:
            problems.append(f"{i}: downgrade {want[i]} -> {got[i]}")
    return (not problems, problems)


def main():
    work = os.path.join(ROOT, "bench", "work")
    ot = os.path.join(os.path.expanduser("~"), "opentitan")
    yosys_slang = os.environ.get("YOSYS_SLANG")
    baseline_path = os.path.join(ROOT, "bench", "recall_baseline.json")
    bless = False
    enforce = False
    args = sys.argv[1:]
    while args:
        if args[0] == "--work":
            work, args = args[1], args[2:]
        elif args[0] == "--ot":
            ot, args = args[1], args[2:]
        elif args[0] == "--yosys":
            yosys_slang, args = args[1], args[2:]
        elif args[0] == "--baseline":
            baseline_path, args = args[1], args[2:]
        elif args[0] == "--bless":
            bless, args = True, args[1:]
        elif args[0] == "--enforce":
            enforce, args = True, args[1:]
        else:
            sys.exit(f"recall: unknown flag {args[0]}")
    os.makedirs(work, exist_ok=True)
    if any(not os.path.exists(os.path.join(work, f"t2-{d['name']}.json"))
           for d in TIER2):
        elaborate_tier2(work, ot, yosys_slang)
    binary = os.path.join(ROOT, "zig-out", "bin", "icarium")
    rules = subprocess.run([binary, "rules", "--list"], capture_output=True,
                           text=True).stdout.split()
    oracle = json.load(open(os.path.join(ROOT, "bench", "waiver_oracle.json")))
    have = {d["name"] for d in TIER2
            if os.path.exists(os.path.join(work, f"t2-{d['name']}.json"))}
    report = {"blocks": {}, "entries": [], "pending": []}
    for spec in TIER2:
        findings, err = check_block(binary, work, spec)
        if err:
            report["blocks"][spec["name"]] = {"error": err}
            continue
        js = json.load(open(os.path.join(work, f"t2-{spec['name']}.json")))
        mod = js["modules"][spec["top"]]
        blob = "\n".join([norm(c) for c in mod["cells"]] +
                         [norm(p) for p in mod["ports"]])
        mine = [e for e in oracle["entries"]
                if e.get("block") == spec["name"]]
        counts = {"full": 0, "partial": 0, "rule-only": 0, "missed": 0,
                  "modeling-gap": 0,
                  "pending-reserved": 0, "pending-clock-model": 0,
                  "pending-out-of-scope": 0}
        for e in mine:
            if not set(e["icarium_rules"]) & set(rules):
                counts["pending-reserved"] += 1
                report["pending"].append({**e, "reason": "reserved-only"})
                continue
            v, f = verdict(e, findings, blob)
            if v.startswith("pending-"):
                counts[v] += 1
                report["pending"].append({**e, "reason": v})
                continue
            counts[v] += 1
            report["entries"].append({
                "id": e["id"], "block": spec["name"],
                "meridian_rule": e["meridian_rule"],
                "icarium_rules": e["icarium_rules"],
                "verdict": v,
                "finding": {k: f[k] for k in ("rule", "dst", "driver")}
                if f else None})
        report["blocks"][spec["name"]] = {
            "findings": len(findings), **counts}
    chip = [e for e in oracle["entries"] if e["scope"] == "chip"]
    other = [e for e in oracle["entries"]
             if e.get("block") not in have and e["scope"] == "block"]
    report["pending-chip"] = len(chip)
    report["pending-block"] = len(other)
    json.dump(report, open(os.path.join(ROOT, "bench", "recall.json"), "w"),
              indent=1)
    for name, b in report["blocks"].items():
        if "error" in b:
            print(f"recall {name}: {b['error']}")
            continue
        denom = b["full"] + b["partial"] + b["rule-only"] + \
            b["missed"] + b["modeling-gap"]
        hit = b["full"] + b["partial"]
        print(f"recall {name}: {b['findings']} findings, "
              f"{hit}/{denom} endpoint recall "
              f"(full {b['full']}, partial {b['partial']}, "
              f"rule-only {b['rule-only']}, missed {b['missed']}, "
              f"modeling-gap {b['modeling-gap']}, "
              f"reserved {b['pending-reserved']}, "
              f"clock-model {b['pending-clock-model']}, "
              f"out-of-scope {b['pending-out-of-scope']})")
    print(f"recall pending: {len(chip)} chip entries, "
          f"{len(other)} unelaborated-block entries")
    if bless:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                capture_output=True,
                                text=True).stdout.strip()
        blessed = {
            "blessed_at": commit,
            "opentitan": oracle["meta"]["opentitan"],
            "blocks": {n: {k: b[k] for k in
                            ("findings", "full", "partial", "rule-only",
                             "missed", "modeling-gap")}
                       for n, b in report["blocks"].items()
                       if "error" not in b},
            "entries": {e["id"]: e["verdict"]
                        for e in report["entries"]},
        }
        json.dump(blessed, open(baseline_path, "w"), indent=1)
        print(f"recall: baseline blessed at {commit[:12]} "
              f"({len(blessed['entries'])} entries) -> {baseline_path}")
    if enforce:
        if os.path.exists(baseline_path):
            baseline = json.load(open(baseline_path))
            print(f"recall: enforcing against {baseline_path} "
                  f"(blessed at {baseline['blessed_at'][:12]})")
        else:
            baseline = None
            print("recall: no baseline file; absolute gates only")
        ok, problems = compare(baseline, report)
        for p in problems:
            print(f"recall FAIL: {p}")
        if ok:
            print("recall: gate holds")
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
