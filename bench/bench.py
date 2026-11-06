#!/usr/bin/env python3
"""Head-to-head bench: icarium vs rtl-buddy-cdc on identical inputs.

Tiers 1-2 (tier 3 EarlGrey needs --tier3 and a big machine; see the
load-discipline note). Each design: elaborate once, run each tool's
analyze 3x, report median wall + peak RSS + counts, verify every
reference pair is covered by our crossing set, append to results.json.

Usage: python3 bench/bench.py [--tier 1|2|3] [--work DIR] [--ot DIR]
"""
import json
import os
import platform
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from compare import coverage  # noqa: E402
from measure import run_metric  # noqa: E402

TIER1 = sorted(d for d in os.listdir(os.path.join(ROOT, "tests", "e2e"))
               if os.path.isfile(os.path.join(ROOT, "tests", "e2e", d, "design.sv")))
TIER2 = [
    {"name": "uart", "core": "lowrisc:ip:uart:0.1", "top": "uart",
     "sdc": "bench/sdc/uart.sdc"},
    {"name": "spi_device", "core": "lowrisc:ip:spi_device:0.1",
     "top": "spi_device", "sdc": "bench/sdc/spi_device.sdc"},
    {"name": "gpio", "core": "lowrisc:earlgrey_ip:gpio:0.1",
     "top": "gpio", "sdc": "bench/sdc/gpio.sdc"},
    {"name": "alert_handler", "core": "lowrisc:earlgrey_ip:alert_handler:0.1",
     "top": "alert_handler", "sdc": "bench/sdc/alert_handler.sdc"},
    {"name": "lc_ctrl", "core": "lowrisc:ip:lc_ctrl:0.1",
     "top": "lc_ctrl", "sdc": "bench/sdc/lc_ctrl.sdc"},
]


def need(cmd, hint):
    from shutil import which
    if which(cmd) is None:
        print(f"bench: SKIP ({cmd} not on PATH: {hint})")
        sys.exit(0)


def elaborate_tier1(work):
    need("yosys", "stock yosys elaborates fixtures")
    out = {}
    for case in TIER1:
        js = os.path.join(work, f"t1-{case}.json")
        r = subprocess.run(
            ["sh", "scripts/elaborate.sh", "--top", case, "--out", js,
             f"tests/e2e/{case}/design.sv"],
            cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"bench: elaborate failed for {case}\n{r.stderr[-500:]}")
            sys.exit(1)
        sdc = os.path.join(ROOT, "tests", "e2e", case, "constraints.sdc")
        out[case] = {"json": js, "sdc": sdc if os.path.exists(sdc) else None,
                     "top": case}
    return out


def elaborate_tier2(work, ot, yosys_slang):
    from shutil import which
    if which("fusesoc") is None or yosys_slang is None:
        print("bench: tier2 SKIP (needs fusesoc + slang-capable yosys)")
        return {}
    out = {}
    for d in TIER2:
        js = os.path.join(work, f"t2-{d['name']}.json")
        cmd = ["sh", "scripts/elaborate-otip.sh", "--core", d["core"],
               "--top", d["top"], "--out", js, "--ot", ot,
               "--yosys", yosys_slang]
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"bench: elaborate failed for {d['name']}\n{r.stderr[-800:]}")
            sys.exit(1)
        out[d["name"]] = {"json": js, "sdc": os.path.join(ROOT, d["sdc"]),
                          "top": d["top"]}
    return out


def run_tool(kind, binary, js, top, sdc, work, reps):
    """Median analyze-only run. Runs past the first are skipped when a
    single run exceeds two minutes; reps_used records what ran."""
    walls, rss = [], []
    for i in range(reps):
        if kind == "icarium":
            cmd = [binary, "check", "--yosys-json", js, "--top", top,
                   "--format", "json"]
            if sdc:
                cmd += ["--sdc", sdc]
        else:
            cmd = [binary, "analyze", "--netlist", js, "--format", "json"]
            if sdc:
                cmd += ["--sdc", sdc]
        m = run_metric(cmd, cwd=work)
        walls.append(m["wall"])
        rss.append(m["rss_kb"])
        if m["wall"] > 120 and i == 0:
            break
    walls.sort()
    mid = walls[len(walls) // 2]
    return {"wall_s": round(mid, 3), "reps_used": len(walls),
            "rss_kb": max(r for r in rss if r is not None) if any(rss) else None}


def count_ref(path):
    try:
        d = json.load(open(path))
    except Exception:
        return 0, 0
    s = d.get("summary", {})
    return s.get("violations", len(d.get("violations", []))), \
        s.get("async_crossings", len(d.get("crossings", [])))


def count_ours(path):
    try:
        d = json.load(open(path))
    except Exception:
        return 0, 0
    n = sum(len(g.get("items", [])) for g in d.get("groups", []))
    return n, -1  # findings only; crossings counted separately


def bench_design(name, js, top, sdc, work, icarium, ref, reps):
    print(f"bench: {name} ...", flush=True)
    res = {"design": name}
    slug = name.replace("/", "_")
    for kind, binary in (("icarium", icarium), ("ref", ref)):
        m = run_tool(kind, binary, js, top, sdc, work, reps)
        # Re-run once to capture outputs for counting + comparison.
        if kind == "icarium":
            r = subprocess.run(
                [binary, "check", "--yosys-json", js, "--top", top,
                 "--format", "json"] + (["--sdc", sdc] if sdc else []),
                cwd=work, capture_output=True, text=True)
            open(os.path.join(work, f"{slug}.ours.json"), "w").write(r.stdout)
            rx = subprocess.run(
                [binary, "crossings", "--yosys-json", js, "--top", top] +
                (["--sdc", sdc] if sdc else []),
                cwd=work, capture_output=True, text=True)
            open(os.path.join(work, f"{slug}.ours.x"), "w").write(rx.stdout)
            f, _ = count_ours(os.path.join(work, f"{slug}.ours.json"))
            m["findings"] = f
        else:
            r = subprocess.run(
                [binary, "analyze", "--netlist", js, "--format", "json"] +
                (["--sdc", sdc] if sdc else []),
                cwd=work, capture_output=True, text=True)
            open(os.path.join(work, f"{slug}.ref.json"), "w").write(r.stdout)
            f, c = count_ref(os.path.join(work, f"{slug}.ref.json"))
            m["findings"] = f
            m["ref_crossings"] = c
        res[kind] = m
    cov = coverage(os.path.join(work, f"{slug}.ours.x"),
                   os.path.join(work, f"{slug}.ref.json"))
    res["ref_pair_coverage"] = cov
    ours_n = sum(1 for _ in open(os.path.join(work, f"{slug}.ours.x"))
                 if _.startswith("crossing "))
    res["ours_crossings"] = ours_n
    print(f"bench: {name}: icarium {res['icarium']['wall_s']}s / "
          f"ref {res['ref']['wall_s']}s, coverage {cov}", flush=True)
    return res


def machine_spec():
    spec = {"system": platform.system(), "release": platform.release(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count()}
    try:
        if spec["system"] == "Darwin":
            spec["model"] = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True, text=True).stdout.strip()
            spec["mem_bytes"] = int(subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True, text=True).stdout.strip())
        else:
            mem = [l for l in open("/proc/meminfo") if "MemTotal" in l]
            spec["mem_kb"] = int(mem[0].split()[1]) if mem else None
    except Exception:
        pass
    return spec


def versions(icarium):
    out = {}
    try:
        out["icarium"] = subprocess.run(
            [icarium, "version"], capture_output=True, text=True).stdout.strip()
    except Exception:
        out["icarium"] = "unknown"
    try:
        r = subprocess.run(["pip", "show", "rtl-buddy-cdc"],
                           capture_output=True, text=True).stdout
        out["ref"] = next((l.split(":")[1].strip() for l in r.splitlines()
                           if l.startswith("Version:")), "unknown")
    except Exception:
        out["ref"] = "unknown"
    try:
        out["yosys"] = subprocess.run(
            ["yosys", "-V"], capture_output=True, text=True).stdout.strip()
    except Exception:
        out["yosys"] = "unknown"
    return out


def main():
    tiers = {1, 2}
    only = None
    reps = 3
    work = os.path.join(ROOT, "bench", "work")
    ot = os.path.join(os.path.expanduser("~"), "opentitan")
    yosys_slang = os.environ.get("YOSYS_SLANG")
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--tier":
            tiers = {int(args[i + 1])}
            i += 2
        elif args[i] == "--work":
            work = args[i + 1]
            i += 2
        elif args[i] == "--ot":
            ot = args[i + 1]
            i += 2
        elif args[i] == "--only":
            only = args[i + 1]
            i += 2
        elif args[i] == "--reps":
            reps = int(args[i + 1])
            i += 2
        else:
            print(f"bench: bad argument {args[i]}")
            sys.exit(2)
    if 3 in tiers:
        print("bench: tier 3 (full EarlGrey) is not wired to this runner; "
              "run it chunked per the load-discipline note.")
        sys.exit(2)
    need("rtl-buddy-cdc", "pip install from rtl-buddy/rtl-buddy-cdc")
    os.makedirs(work, exist_ok=True)
    icarium = os.path.join(ROOT, "zig-out", "bin", "icarium")
    if not os.path.exists(icarium):
        print("bench: run zig build first (release recommended)")
        sys.exit(2)
    designs = {}
    if 1 in tiers:
        for name, spec in elaborate_tier1(work).items():
            designs[f"t1/{name}"] = spec
    if 2 in tiers:
        for name, spec in elaborate_tier2(work, ot, yosys_slang).items():
            designs[f"t2/{name}"] = spec
    results = []
    for name, spec in designs.items():
        if only is not None and only not in name:
            continue
        results.append(bench_design(name, spec["json"], spec["top"],
                                    spec["sdc"], work, icarium,
                                    "rtl-buddy-cdc", reps))
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                                cwd=ROOT, capture_output=True,
                                text=True).stdout.strip()
    entry = {"date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
             "commit": commit,
             "machine": machine_spec(), "versions": versions(icarium),
             "designs": results}
    path = os.path.join(ROOT, "bench", "results.json")
    try:
        data = json.load(open(path))
    except Exception:
        data = {"runs": []}
    data["runs"].append(entry)
    json.dump(data, open(path, "w"), indent=2)
    print(f"bench: appended run to {path}")


if __name__ == "__main__":
    main()
