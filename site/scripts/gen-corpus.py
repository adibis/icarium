#!/usr/bin/env python3
"""Generate the corpus coverage page from the benchmark manifests.

Reads submodules/icarium_benchmark/cases/tier1/*/manifest.json,
writes site/content/docs/benchmark-corpus/coverage.md. Re-run
after any case change:

    python3 site/scripts/gen-corpus.py
"""
import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CASES = os.path.join(ROOT, "submodules", "icarium_benchmark", "cases", "tier1")
OUT = os.path.join(ROOT, "site", "content", "docs", "benchmark-corpus", "coverage.md")

PREFIX = re.compile(r"^(?:fx_)?((?:cdc|rdc)\d+)_")


def main():
    manifests = sorted(glob.glob(os.path.join(CASES, "*", "manifest.json")))
    if not manifests:
        raise SystemExit("gen-corpus: no manifests under " + CASES)
    firing = {}
    silence = {}
    unattributed = []
    rules = set()
    for mf in manifests:
        m = json.load(open(mf))
        cid = m["id"]
        for e in m["expect"]:
            rules.add(e["rule"])
            firing.setdefault(e["rule"], []).append(cid)
        if not m["expect"]:
            g = PREFIX.match(cid)
            if g is None:
                unattributed.append(cid)
                continue
            raw = g.group(1)
            rid = raw[:3].upper() + "-" + raw[3:]
            silence.setdefault(rid, []).append(cid)
            rules.add(rid)
    for rid in sorted(rules):
        firing.setdefault(rid, [])
        silence.setdefault(rid, [])
    lines = ["---", "title: Coverage", "weight: 30", "---", "",
             f"Tier 1 holds {len(manifests)} cases across {len(rules)} rules. "
             "Firing counts cases whose oracle expects the rule; silence counts "
             "empty-oracle cases built for it. Every rule fires in at least two "
             "cases; silence guards the rules whose approved pattern is worth pinning.",
             "",
             "| rule | firing | silence |",
             "|---|---|---|"]
    for rid in sorted(rules):
        lines.append(f"| {rid} | {len(firing[rid])} | {len(silence[rid])} |")
    if unattributed:
        lines += ["",
                  "Unattributed silence (" + ", ".join(f"`{c}`" for c in sorted(unattributed)) + "):",
                  "end-to-end quiet designs with no single target rule.",
                  ""]
    lines += ["",
              "Case-level oracles live in the corpus repo: each case pairs",
              "`design.sv` and `design.sdc` with a `manifest.json` pinning the",
              "exact expected findings.",
              ""]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w").write("\n".join(lines) + "\n")
    print(f"coverage: {len(manifests)} cases, {len(rules)} rules")


if __name__ == "__main__":
    main()
