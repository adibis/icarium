#!/usr/bin/env python3
"""Generate the rule reference pages from the pinned rules doc.

Reads tests/snapshots/rules-doc.txt (precommit-pinned output of
`icarium rules --doc`) plus fixtures/<ID>/ manifests and .sv/.sdc
pairs, writes site/content/docs/rules/_index.md and one page per
rule. Re-run after any rule doc or fixture change:

    python3 site/scripts/gen-rules.py
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "site", "content", "docs", "rules")
SEV = {"err": "error", "warn": "warning", "note": "note"}


def parse_rules_doc(path):
    blocks = open(path).read().strip().split("\n\n")
    rules = []
    for b in blocks:
        lines = b.splitlines()
        m = re.match(r"(\S+) \[(\w+)\] (.*)", lines[0])
        rid, sev, title = m.groups()
        honors, fixdir, doc = "", "", []
        for ln in lines[1:]:
            if ln.startswith("honors:"):
                honors = ln[len("honors:"):].strip()
            elif ln.startswith("fixtures:"):
                fixdir = ln[len("fixtures:"):].strip()
            else:
                doc.append(ln)
        rules.append({"id": rid, "sev": sev, "title": title,
                      "doc": "\n".join(doc).strip(),
                      "honors": honors.split(), "fixdir": fixdir})
    return rules


def load_fixture(r):
    d = os.path.join(ROOT, r["fixdir"])
    man = json.load(open(os.path.join(d, "manifest.json")))
    bad = sorted(f for f, rs in man.items() if r["id"] in rs)
    good = sorted(f for f, rs in man.items() if not rs)
    return d, bad, good


def codeblock(path):
    return "```systemverilog\n" + open(path).read().rstrip() + "\n```"


def sdcblock(path):
    return "```tcl\n" + open(path).read().rstrip() + "\n```"


def page(r, weight):
    d, bad, good = load_fixture(r)
    # Bare (* mark *) reads as emphasis; code-span it.
    doc = re.sub(r"\(\* ([a-z_]+) \*\)", r"`(* \1 *)`", r["doc"])
    L = ["---", f"title: \"{r['id']}: {r['title']}\"", f"linkTitle: \"{r['id']} {r['title']}\"",
         f"weight: {weight}", "---", "",
         f"**Severity:** {SEV.get(r['sev'], r['sev'])}", ""]
    L += [doc, ""]
    if r["honors"]:
        marks = ", ".join(f"`(* {h} *)`" for h in r["honors"])
        L += ["## Suppression marks", "",
              f"This rule honors: {marks}.", ""]
    if bad:
        L += ["## Failing example", ""]
        b = bad[0]
        L += [f"`fixtures/{r['id']}/{b}`:", "", codeblock(os.path.join(d, b)), ""]
        s = os.path.splitext(b)[0] + ".sdc"
        if os.path.exists(os.path.join(d, s)):
            L += [f"with `fixtures/{r['id']}/{s}`:", "", sdcblock(os.path.join(d, s)), ""]
        if len(bad) > 1:
            rest = ", ".join(f"`{f}`" for f in bad[1:])
            L += [f"More failing cases: {rest}.", ""]
    if good:
        L += ["## Passing examples", ""]
        for g in good:
            why = os.path.splitext(g)[0].replace("good_", "").replace("_", " ")
            L += [f"- `{g}` — clean ({why})"]
        L += [""]
    return "\n".join(L)


def first_sentence(doc):
    one = re.sub(r"\s+", " ", doc).strip()
    head = one.split(". ")[0]
    if not head.endswith("."):
        head += "."
    return re.sub(r"\(\* ([a-z_]+) \*\)", r"`(* \1 *)`", head)


def index(rules):
    L = ["---", "title: Rule catalog", "linkTitle: Rules", "weight: 40", "---", "",
         "One page per rule: what it flags, which suppression marks it",
         "honors, and the paired failing/passing fixtures. Pages are",
         "generated from `icarium rules --doc` — see",
         "`site/scripts/gen-rules.py`.", "",
         "| Rule | Severity | What it flags |", "| ---- | -------- | ------------- |"]
    for r in rules:
        slug = r["id"].lower()
        L.append(f"| [{r['title']}]({slug}/) ({r['id']}) "
                 f"| {SEV.get(r['sev'], r['sev'])} | {first_sentence(r['doc'])} |")
    return "\n".join(L) + "\n"


def main():
    rules = parse_rules_doc(os.path.join(ROOT, "tests", "snapshots", "rules-doc.txt"))
    os.makedirs(OUT, exist_ok=True)
    for i, r in enumerate(rules):
        assert r["id"] not in ("CDC-007",), "unexpected rule id"
        with open(os.path.join(OUT, r["id"].lower() + ".md"), "w") as f:
            f.write(page(r, 100 + i))
    with open(os.path.join(OUT, "_index.md"), "w") as f:
        f.write(index(rules))
    print(f"wrote {len(rules)} rule pages to {OUT}")


if __name__ == "__main__":
    main()
