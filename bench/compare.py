"""Reference-pair coverage: every (src, dst) pair the reference reports
must appear in our async crossing set. Our extras are expected (we
enumerate transitively; the reference caps hop depth), so coverage is
one-directional by design."""
import json


def endpoint(ep):
    p = ep.split(":")
    return ("port", p[1]) if p[0] == "p" else ("cell", ":".join(p[1:-2]))


def coverage(ours_x_path, ref_json_path):
    try:
        ref = json.load(open(ref_json_path))
    except Exception:
        return {"ref_pairs": 0, "missed": -1, "note": "ref output unreadable"}
    want = set()
    for x in ref.get("crossings", []):
        s = x.get("src_flop") or x.get("src_port") or x.get("src_boundary_pin")
        want.add((s, x.get("dst_flop")))
    ours = set()
    try:
        for line in open(ours_x_path):
            p = line.split()
            if not p or p[0] != "crossing":
                continue
            if p[2] in ("clock_sink", "clock_control"):
                continue
            if len(p) < 9 or p[8] != "true":
                continue
            ours.add((endpoint(p[3])[1], endpoint(p[4])[1]))
    except Exception:
        return {"ref_pairs": len(want), "missed": -1,
                "note": "ours output unreadable"}
    # Reference names cells bare; our endpoints carry instance paths
    # that end in the same leaf. Suffix-match to bridge the spellings.
    def norm(name):
        return name.split("/")[-1] if name else name
    ours_norm = set((norm(s), norm(d)) for s, d in ours)
    missed = sorted((s, d) for s, d in want
                    if (norm(s), norm(d)) not in ours_norm)
    return {"ref_pairs": len(want), "missed": len(missed),
            "miss_sample": [f"{s}->{d}" for s, d in missed[:5]]}
