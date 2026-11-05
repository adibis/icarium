"""One timed run with peak RSS via /usr/bin/time (per-process, so 3x
medians stay honest). Exit codes pass through: finding-bearing runs
exit 1 from both tools, which is success here, not failure."""
import re
import subprocess
import sys
import time


def run_metric(cmd, cwd):
    timer = ["/usr/bin/time", "-l"] if sys.platform == "darwin" \
        else ["/usr/bin/time", "-v"]
    t0 = time.monotonic()
    p = subprocess.run(timer + cmd, cwd=cwd, capture_output=True, text=True)
    wall = time.monotonic() - t0
    rss_kb = None
    if sys.platform == "darwin":
        # "12345  maximum resident set size" (bytes, number first).
        m = re.search(r"(\d+)\s+maximum resident set size", p.stderr, re.I)
        if m:
            rss_kb = int(m.group(1)) // 1024
    else:
        # "Maximum resident set size (kbytes): 1234".
        m = re.search(r"Maximum resident set size[^:]*:\s*(\d+)", p.stderr, re.I)
        if m:
            rss_kb = int(m.group(1))
    return {"wall": wall, "rss_kb": rss_kb, "exit": p.returncode,
            "stdout": p.stdout, "stderr": p.stderr[-2000:]}
