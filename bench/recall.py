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
                             [--chip] [--reuse-findings]

--chip also measures chip-scope oracle entries against a streamed
full-top check (about an hour plus matching); without it they
stay pending-counted as before.

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
from functools import lru_cache

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from bench import TIER2, elaborate_tier2  # noqa: E402

STRIP = "*?{}\"' "
PREFIXES = ("top_earlgrey.u_spi_device.", "top_earlgrey.u_uart.",
            "top_earlgrey.", "u_spi_device.", "u_uart.", "$driver$")

# Waiver hierarchies predate elaboration renames: _aon wrappers
# flatten under shorter names, and u_ast splits across two parts.
SEG_ALIASES = {"u_pinmux_aon": "u_pinmux", "u_clkmgr_aon": "u_clkmgr",
               "u_pwrmgr_aon": "u_pwrmgr", "u_rstmgr_aon": "u_rstmgr"}
# Single known wrapper: waivers predate the JTAG gating layer
# around the debug port, so drop it on both sides to compare.
WRAPPER_DROP = {"gen_jtag_gating"}
AST_SPLIT = ("u_ast_part_primary", "u_ast_part_secondary")
BRACKETS = re.compile(r"\[[^\]]*\]")


@lru_cache(maxsize=None)
def norm(s):
    if not s:
        return ""
    # Brackets index the copy, not the path: drop them but keep
    # walking, or generated hierarchies vanish below the index.
    s = BRACKETS.sub("", s)
    s = s.strip().strip(STRIP).lstrip(".")
    changed = True
    while changed:
        changed = False
        s = s.lstrip(".")
        for pre in PREFIXES:
            if s.startswith(pre):
                s = s[len(pre):].lstrip(".")
                changed = True
    # .invert is a waiver polarity note, never hierarchy.
    if s.endswith(".invert"):
        s = s[:-len(".invert")]
    s = ".".join(SEG_ALIASES.get(g, g) for g in s.split(".")
                if g not in WRAPPER_DROP)
    return s.strip().strip(STRIP).strip(".")


PINS = {"q", "q_o", "d", "clk", "rst", "rst_n", "arst", "srst", "en",
        "s", "a", "b", "y", "clk_i", "rst_ni", "tck"}


@lru_cache(maxsize=None)
def variants(s):
    segs = [g for g in norm(s).split(".") if g]
    out = []
    if segs:
        out.append(".".join(segs))
    # A trailing _o/_i names the pin a signal exits through; the
    # parent cell is what findings and the blob can match.
    if len(segs) > 1 and re.match(r"^.+_[oi]$", segs[-1]):
        out.append(".".join(segs[:-1]))
    while segs and segs[-1].lower() in PINS:
        segs.pop()
        if segs:
            out.append(".".join(segs))
    for v in list(out):
        vs = v.split(".")
        if "u_ast" in vs:
            for alt in AST_SPLIT:
                out.append(".".join(alt if g == "u_ast" else g
                                    for g in vs))
    return list(dict.fromkeys(out))


@lru_cache(maxsize=None)
def rx(s):
    return re.compile(re.escape(s).replace(r"\*", ".*")
                      .replace(r"\?", "."))


# ASIC pads live outside the synthesized netlist, so pad ends
# excuse measurability. Families from pinout_asic.md.
PAD_PINOUT = re.compile(r"^\*?(IO[ABC]?\d*|IOR\d*|SPI_[A-Z0-9_]*"
                        r"|USB_[A-Z0-9_]*|POR_N|CC[12]|RRAM_ANALOG)\*?$")


@lru_cache(maxsize=None)
def suffix_variants(s):
    segs = [g for g in norm(s).split(".") if g]
    # Wrapper insertions drift middle hierarchy; the tail still
    # names the same signal. Last resort, anchored at overlap.
    if len(segs) > 2:
        return [".".join(segs[1:])]
    # Short tails match everywhere; long ones name the signal.
    if len(segs) == 2 and len(segs[-1]) >= 8 and \
       "*" not in segs[-1] and "?" not in segs[-1]:
        return [segs[-1]]
    return []


def end_in_blob(s, blob):
    if any(rx(v).search(blob) for v in variants(s)):
        return True
    suf = suffix_variants(s)
    if not suf:
        return False
    anchor = norm(s).split(".")[0]
    return rx(anchor).search(blob) is not None and \
        any(rx(v).search(blob) for v in suf)


# Pad-ring cells elaborate away with the ring: hierarchy under
# u_padring excuses like pad names, never locates.
PAD_HIER = ("u_padring.",)


def end_ok(s, blob):
    if "." not in s and PAD_PINOUT.match(s) is not None:
        return True
    if norm(s).startswith(PAD_HIER):
        return True
    return end_in_blob(s, blob)


def overlap(pattern, name):
    pv, nv = variants(pattern), variants(name)
    if _hit(pv, nv):
        return True
    # Suffix hits need the block anchor in the same endpoint, or
    # tails from different blocks would match each other.
    suf = suffix_variants(pattern)
    if not suf or not nv:
        return False
    anchor = rx(norm(pattern).split(".")[0])
    for p in suf:
        rp = rx(p)
        for n in nv:
            if anchor.search(n) is not None and \
               (rp.search(n) or rx(n).search(p)):
                return True
    return False


def _hit(pv, nv):
    if not pv or not nv:
        return False
    for p in pv:
        rp = rx(p)
        for n in nv:
            if rp.search(n) or rx(n).search(p):
                return True
    return False


def check_block(binary, work, spec, reuse=False):
    name = spec["name"]
    js = os.path.join(work, spec.get("netlist", f"t2-{name}.json"))
    out = os.path.join(work, f"recall-{name}.findings.json")
    if not os.path.exists(js):
        return None, f"no netlist {js}"
    if reuse:
        # Matching iterates far more often than checking; a chip
        # re-match must not cost another hour-long recheck.
        if not os.path.exists(out):
            return None, f"no cached findings {out} (run without --reuse-findings)"
    else:
        cmd = [binary, "check", "--yosys-json", js,
               "--top", spec["top"],
               "--sdc", os.path.join(ROOT, spec["sdc"]),
               "--format", "json"]
        if spec.get("stream"):
            cmd += ["--stream", "--stream-chunk",
                    str(spec.get("chunk", 256)), "--pair-budget",
                    str(spec.get("budget", 2000000))]
        r = subprocess.run(cmd, capture_output=True, text=True)
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


def build_rule_index(findings):
    idx = {}
    for f in findings:
        idx.setdefault(f["rule"], []).append(f)
    return idx


GAP_RULES = ("CDC-025", "CDC-011", "CDC-021")

# These file under blocks but need the full clock tree to judge:
# module selects hang off ports CDC-010 defers by design.
CHIP_CONTEXT_RULES = {"W_G_CLK_GLITCH"}


@lru_cache(maxsize=None)
def token(s):
    toks = [t for t in re.split(r"[*?]", s) if t]
    return max(toks, key=len) if toks else ""


def verdict(entry, cands, gap_pool, blob):
    if not entry["driver"] and not entry["dst"]:
        return "pending-clock-model", None, ["driver", "dst"]
    given = [(k, entry[k]) for k in ("driver", "dst") if entry[k]]
    if blob is not None:
        unloc = [k for k, s in given if not end_ok(s, blob)]
        if len(unloc) == len(given):
            return "pending-out-of-scope", None, unloc
        both_located = all(end_in_blob(s, blob) for _, s in given)
    else:
        unloc = []
        both_located = True
    if not cands:
        for f in gap_pool:
            if overlap(entry["driver"], f["driver"]) or \
               overlap(entry["driver"], f["dst"]) or \
               overlap(entry["dst"], f["dst"]) or \
               overlap(entry["dst"], f["driver"]):
                return "modeling-gap", f, unloc
        return "missed", None, unloc
    # Single-ended entries can never satisfy d-and-r (a null end
    # never overlaps), so the given end alone decides full. Weaker
    # evidence than a two-ended match; documented, not hidden.
    single = bool(entry["driver"]) != bool(entry["dst"])
    dpats = (variants(entry["driver"]) +
             suffix_variants(entry["driver"])) if entry["driver"] else []
    rpats = (variants(entry["dst"]) +
             suffix_variants(entry["dst"])) if entry["dst"] else []
    # Longest tokens first: most findings reject on the first
    # substring check instead of the tenth.
    toks = sorted([token(v) for v in dpats + rpats if token(v)],
                  key=len, reverse=True)
    joined = " ".join(dpats + rpats)
    wild = any(v and not token(v) for v in dpats + rpats)
    for f in cands:
        if not wild and not _prefilter(f, toks, joined):
            continue
        d = overlap(entry["driver"], f["driver"]) or \
            overlap(entry["driver"], f["dst"])
        r = overlap(entry["dst"], f["dst"]) or \
            overlap(entry["dst"], f["driver"])
        if d and r and both_located:
            return "full", f, unloc
        if single and (d or r) and both_located:
            return "full", f, unloc
    for f in cands:
        if not wild and not _prefilter(f, toks, joined):
            continue
        if overlap(entry["driver"], f["driver"]) or \
           overlap(entry["driver"], f["dst"]) or \
           overlap(entry["dst"], f["dst"]) or \
           overlap(entry["dst"], f["driver"]):
            return "partial", f, unloc
    return "rule-only", cands[0], unloc


def _prefilter(f, toks, joined):
    # Literal tokens prune regexes both directions: a regex hit
    # needs its longest literal present, so absence skips safely.
    # One joined scan per token; newline-free tokens cannot span.
    fends = [n for e in (f["driver"], f["dst"]) if e
             for n in variants(e)]
    if not fends:
        return False
    flat = "\n".join(fends)
    for t in toks:
        if t in flat:
            return True
    return any(token(n) in joined for n in fends
               if token(n))


RANK = {"full": 3, "partial": 2, "rule-only": 1, "missed": 0,
        "modeling-gap": 0}


def compare(baseline, report):
    # Misses fail absolutely and are never blessed; gaps tripwire
    # (blessed hold, new fail). Upgrades pass, drops fail.
    problems = []
    for name, b in report["blocks"].items():
        if "error" in b:
            problems.append(f"{name}: {b['error']}")
            continue
        if b["missed"]:
            problems.append(f"{name}: {b['missed']} missed")
        if b["modeling-gap"] and baseline is None:
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


def measure_scope(spec, findings, work, oracle, rules, report,
                  entries=None):
    name = spec["name"]
    js = json.load(open(os.path.join(
        work, spec.get("netlist", f"t2-{name}.json"))))
    mod = js["modules"][spec["top"]]
    # Nets join cells and ports: waivers name pins and wires,
    # which elaborate to netnames rather than cells.
    blob = "\n".join([norm(c) for c in mod["cells"]] +
                     [norm(p) for p in mod["ports"]] +
                     [norm(n) for n in mod.get("netnames", ())])
    if entries is None:
        entries = [e for e in oracle["entries"]
                   if e.get("block") == name and
                   e["meridian_rule"] not in CHIP_CONTEXT_RULES]
    idx = build_rule_index(findings)
    gap_pool = [f for r in GAP_RULES for f in idx.get(r, [])]
    counts = {"full": 0, "partial": 0, "rule-only": 0, "missed": 0,
              "modeling-gap": 0,
              "pending-reserved": 0, "pending-clock-model": 0,
              "pending-out-of-scope": 0}
    for e in entries:
        if not set(e["icarium_rules"]) & set(rules):
            counts["pending-reserved"] += 1
            report["pending"].append({**e, "reason": "reserved-only"})
            continue
        cands = [f for r in e["icarium_rules"] for f in idx.get(r, [])]
        v, f, unloc = verdict(e, cands, gap_pool, blob)
        if v.startswith("pending-"):
            counts[v] += 1
            report["pending"].append({**e, "reason": v,
                                      "unlocated": unloc})
            continue
        counts[v] += 1
        report["entries"].append({
            "id": e["id"], "block": name,
            "meridian_rule": e["meridian_rule"],
            "icarium_rules": e["icarium_rules"],
            "verdict": v,
            "finding": {k: f[k] for k in ("rule", "dst", "driver")}
            if f else None})
    report["blocks"][name] = {
        "findings": len(findings), **counts}


def main():
    work = os.path.join(ROOT, "bench", "work")
    ot = os.path.join(os.path.expanduser("~"), "opentitan")
    yosys_slang = os.environ.get("YOSYS_SLANG")
    baseline_path = os.path.join(ROOT, "bench", "recall_baseline.json")
    bless = False
    enforce = False
    run_chip = False
    reuse = False
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
        elif args[0] == "--chip":
            run_chip, args = True, args[1:]
        elif args[0] == "--reuse-findings":
            reuse, args = True, args[1:]
        else:
            sys.exit(f"recall: unknown flag {args[0]}")
    os.makedirs(work, exist_ok=True)
    if any(not os.path.exists(os.path.join(work, f"t2-{d['name']}.json"))
           for d in TIER2):
        elaborate_tier2(work, ot, yosys_slang)
    binary = os.path.join(ROOT, "zig-out", "bin", "icarium")
    rules = subprocess.run([binary, "rules", "--list"], capture_output=True,
                           text=True).stdout.split()
    oracle_path = os.path.join(ROOT, "bench", "waiver_oracle.json")
    if not os.path.exists(oracle_path):
        print("recall: waiver oracle missing, rebuilding via oracle.py")
        r = subprocess.run([sys.executable,
                            os.path.join(ROOT, "bench", "oracle.py"),
                            "--ot", ot])
        if r.returncode != 0 or not os.path.exists(oracle_path):
            sys.exit("recall: cannot build waiver oracle "
                     "(needs OpenTitan checkout via --ot or OTIP)")
    oracle = json.load(open(oracle_path))
    have = {d["name"] for d in TIER2
            if os.path.exists(os.path.join(work, f"t2-{d['name']}.json"))}
    report = {"blocks": {}, "entries": [], "pending": []}
    for spec in TIER2:
        findings, err = check_block(binary, work, spec, reuse)
        if err:
            report["blocks"][spec["name"]] = {"error": err}
            continue
        measure_scope(spec, findings, work, oracle, rules, report)
    chip = [e for e in oracle["entries"]
            if e["scope"] == "chip" or
            e["meridian_rule"] in CHIP_CONTEXT_RULES]
    other = [e for e in oracle["entries"]
             if e.get("block") not in have and e["scope"] == "block" and
             e["meridian_rule"] not in CHIP_CONTEXT_RULES]
    if run_chip:
        spec = {"name": "top_earlgrey", "top": "top_earlgrey",
                "sdc": "bench/sdc/top_earlgrey.sdc",
                "netlist": "t3-top_earlgrey.json", "stream": True}
        findings, err = check_block(binary, work, spec, reuse)
        if err:
            report["blocks"]["top_earlgrey"] = {"error": err}
        else:
            measure_scope(spec, findings, work, oracle, rules, report,
                          entries=chip)
            chip = []
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
