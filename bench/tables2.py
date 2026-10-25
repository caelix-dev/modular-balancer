"""Prints the round-2 tables of docs/benchmarks.md (before/after the network optimisation, plain
against Better Belt Balancer) from docs/benchmarks/raw/r2-*.json and r2b-*.json.

usage: python -I bench/tables2.py

Each ratio and output mode was measured as one block, back to back: BBB, mb (before), mb1 (after),
plain0 (recirc off, before), plain1 (recirc off, after), BBB again. The BBB reference pools both
BBB runs (20 run medians). Noise of "X against BBB" = 2 * sqrt(sd_X^2 / n_X + sd_B^2 / n_B) over
the run medians. 9:1 has one output, so its network is the same merge tree in every variant
(mb1 = mb, plain1 = plain0, and plain = mb).
"""

import json
import math
import os
import statistics

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "benchmarks", "raw")
RATIOS = [("2x3", 50), ("3x5", 50), ("8x3", 50), ("9x1", 50), ("17x2", 50), ("33x5", 50), ("64x64", 4)]
VARIANTS = [("mb", "recirculating, before"), ("mb1", "recirculating, after"),
            ("plain0", "plain (recirc off), before"), ("plain1", "plain (recirc off), after")]
ALIAS_9X1 = {"mb1": "mb", "plain1": "plain0"}


def load(name):
    path = os.path.join(ROOT, name + ".json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def runs(d):
    return d["metrics"]["wholeUpdate"]["run_medians_ms"]


def network_size(d, copies):
    for k, v in (d.get("counts") or {}).items():
        if k == "mb-hidden":
            by = v["by_name"]
            # minus the buffer merge splitter of every network
            sp = by.get("mb-hidden-splitter-express", 0) / copies - 1
            lb = by.get("mb-hidden-linked-belt-express", 0) / copies
            return f"{sp:.0f} / {lb:.0f}"
        if k == "bbb-hidden":
            by = v["by_name"]
            sp = by.get("bbb-splitter", 0) / copies
            ls = by.get("bbb-lane-splitter", 0) / copies
            lb = (by.get("bbb-linked-belt", 0) + (d["counts"]["nauvis"]["by_name"].get("bbb-linked-belt", 0))) / copies
            return f"{sp:.0f} + {ls:.0f} lane / {lb:.0f} (+{by.get('bbb-belt', 0) / copies:.0f} belts)"
    return "-"


def main():
    fails = {"mb1": [], "plain1": [], "plain0": [], "mb": []}
    for ratio, copies in RATIOS:
        n, m = ratio.split("x")
        print(f"### {copies} x {n}:{m}\n")
        print("| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? "
              "| splitters / linked belts per network |")
        print("| --- | --- | --- | --- | --- | --- | --- |")
        for mode in ("free", "thr"):
            outputs = "all free" if mode == "free" else "one throttled"
            b1, b2 = load(f"r2-bbb-{ratio}-{mode}"), load(f"r2b-bbb-{ratio}-{mode}")
            br = runs(b1) + runs(b2)
            bmed, bsd = statistics.median(br), statistics.stdev(br)
            print(f"| Better Belt Balancer | {outputs} | {bmed:.3f} [{min(br):.3f}..{max(br):.3f}] (20 runs) | | | "
                  f"| {network_size(b1, copies)} |")
            for kind, label in VARIANTS:
                name = ALIAS_9X1.get(kind, kind) if ratio == "9x1" else kind
                d = load(f"r2-{name}-{ratio}-{mode}")
                if d is None:
                    continue
                r = runs(d)
                med, sd = statistics.median(r), statistics.stdev(r)
                noise = 2 * math.sqrt(sd ** 2 / len(r) + bsd ** 2 / len(br))
                delta = med - bmed
                ok = delta <= noise
                if not ok:
                    fails[kind].append(f"{n}:{m} {outputs} ({med / bmed:.2f}x)")
                same = " (same network as before)" if ratio == "9x1" and kind in ALIAS_9X1 else ""
                print(f"| {label}{same} | {outputs} | {med:.3f} [{min(r):.3f}..{max(r):.3f}] | "
                      f"{med / bmed:.2f}x ({delta:+.3f}) | {noise:.3f} | {'yes' if ok else '**no**'} "
                      f"| {network_size(d, copies)} |")
        print()
    for kind, label in VARIANTS:
        f = fails[kind]
        print(f"- {label}: " + ("below 2 SE of BBB at every ratio" if not f else "more than 2 SE above BBB at " + ", ".join(f)))


if __name__ == "__main__":
    main()
