"""Summarizes one benchmark save for docs/benchmarks.md.

usage: python -I bench/summarize.py NAME COMPARE_JSON [TICKLENS_JSON] [COUNTS_JSON]

COMPARE_JSON is the output of the fdev MCP tool benchmark_compare (an A/A comparison: two
instances with the same mods alternating on one save, so 2 x rounds runs). TICKLENS_JSON is
`ticklens report --json` of the same save running on an fdev server. COUNTS_JSON is the
result of remote.call("mb-test", "bench_counts"). Writes docs/benchmarks/raw/NAME.json and
prints one line.
"""

import json
import os
import statistics
import sys

METRICS = ["wholeUpdate", "gameUpdate", "transportLinesUpdate", "entityUpdate", "scriptUpdate"]


def runs_of(cmp, metric):
    out = []
    for side in ("a", "b"):
        m = cmp[side]["metrics"].get(metric)
        if m:
            out.extend(m["run_medians_ms"])
    return out


def main():
    name, cmp_path = sys.argv[1], sys.argv[2]
    tl_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "-" else None
    counts_path = sys.argv[4] if len(sys.argv) > 4 else None
    with open(cmp_path, encoding="utf-8") as f:
        cmp = json.load(f)
    summary = {"name": name, "mods": cmp["a"]["mods"], "runs": cmp["a"]["runs"] + cmp["b"]["runs"],
               "ticks_per_run": cmp["a"]["ticks_per_run"], "metrics": {}}
    for metric in METRICS:
        r = runs_of(cmp, metric)
        if not r:
            continue
        summary["metrics"][metric] = {
            "median_ms": statistics.median(r),
            "min_ms": min(r),
            "max_ms": max(r),
            "stdev_ms": statistics.stdev(r) if len(r) > 1 else 0.0,
            "run_medians_ms": r,
            "aa_delta_pct": cmp["delta_pct"].get(metric),
        }
    if tl_path:
        with open(tl_path, encoding="utf-8") as f:
            tl = json.load(f)
        eng = tl.get("engine") or {}
        cats = {c["field"]: c for c in eng.get("categories", [])}
        summary["ticklens"] = {
            "elapsed_s": tl["elapsed_s"],
            "ticks": eng.get("ticks"),
            "wholeUpdate_mean_ms": cats.get("wholeUpdate", {}).get("mean_ms"),
            "scriptUpdate_mean_ms": cats.get("scriptUpdate", {}).get("mean_ms"),
            "engine_mod_mean_ms": {m["name"]: m["mean_ms"] for m in eng.get("mods", [])},
            "engine_mod_max_ms": {m["name"]: m["max_ms"] for m in eng.get("mods", [])},
            "sampled_mod_self_ms": {m["name"]: m["self_ms"] for m in tl.get("mods", [])},
            "samples": tl["stats"]["samples"],
            "idle": tl["stats"]["idle"],
        }
    if counts_path:
        with open(counts_path, encoding="utf-8") as f:
            summary["counts"] = json.load(f)
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "benchmarks", "raw")
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, name + ".json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
        f.write("\n")
    w = summary["metrics"]["wholeUpdate"]
    tlm = summary.get("ticklens", {}).get("engine_mod_mean_ms", {})
    print(f"{name}: wholeUpdate median {w['median_ms']:.4f} [{w['min_ms']:.4f}..{w['max_ms']:.4f}] "
          f"A/A {w['aa_delta_pct']:+.1f}% script mods {tlm}")


if __name__ == "__main__":
    main()
