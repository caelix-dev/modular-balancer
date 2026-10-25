"""Prints the docs/benchmarks.md tables from docs/benchmarks/raw/*.json (bench/summarize.py).

usage: python -I bench/tables.py

Noise of a comparison X vs Better Belt Balancer: 2 * sqrt(sd_x^2 / n_x + sd_b^2 / n_b), where sd is
the standard deviation of a save's run medians (n = 10 runs: 5 A/A rounds of 2 instances). A
difference of medians larger than that is outside the noise (about a 95 % bound).
"""

import json
import math
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "benchmarks", "raw")
SCENARIOS = [("2x3", 50), ("3x5", 50), ("8x3", 50), ("9x1", 50), ("17x2", 50), ("33x5", 50),
             ("64x64", 4), ("96x96", 4), ("128x128", 4)]
KINDS = [("mb", "modular-balancer"), ("bbb", "Better Belt Balancer"), ("bb3", "Belt Balancer 3"),
         ("plain", "plain splitter network (vanilla reference)")]
SCRIPT_MOD = {"mb": "modular-balancer", "plain": "modular-balancer", "bbb": "better-belt-balancer",
              "bb3": "belt-balancer-3-unofficial-2-1"}


def load(name):
    path = os.path.join(ROOT, name + ".json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def entities(d):
    c = d.get("counts") or {}
    vis = c.get("nauvis", {}).get("total", 0)
    hid = sum(v["total"] for k, v in c.items() if k != "nauvis")
    return vis, hid


def script_ms(d, kind):
    tl = d.get("ticklens")
    if not tl:
        return "-"
    eng = tl["engine_mod_mean_ms"].get(SCRIPT_MOD[kind], 0.0)
    smp = tl["sampled_mod_self_ms"].get(SCRIPT_MOD[kind], 0.0)
    return f"{eng:.4f} ({smp:.1f} ms sampled)"


def noise(a, b):
    ma, mb = a["metrics"]["wholeUpdate"], b["metrics"]["wholeUpdate"]
    na, nb = len(ma["run_medians_ms"]), len(mb["run_medians_ms"])
    return 2 * math.sqrt(ma["stdev_ms"] ** 2 / na + mb["stdev_ms"] ** 2 / nb)


def main():
    fails = []
    for ratio, copies in SCENARIOS:
        n, m = ratio.split("x")
        print(f"### {copies} x {n}:{m}\n")
        print("| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate "
              "| script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for mode in ("free", "thr"):
            bbb = load(f"bbb-{ratio}-{mode}")
            for kind, label in KINDS:
                d = load(f"{kind}-{ratio}-{mode}")
                outputs = "all free" if mode == "free" else "one throttled"
                if d is None:
                    if kind == "bbb" and ratio in ("96x96", "128x128"):
                        print(f"| {label} | {outputs} | not supported (port limit 64) | | | | | | | |")
                    continue
                w = d["metrics"]["wholeUpdate"]
                tlu = d["metrics"]["transportLinesUpdate"]["median_ms"]
                eu = d["metrics"]["entityUpdate"]["median_ms"]
                vis, hid = entities(d)
                rel, nz, gate = "", "", ""
                if bbb is not None and kind != "bbb":
                    b = bbb["metrics"]["wholeUpdate"]
                    delta = w["median_ms"] - b["median_ms"]
                    nz_v = noise(d, bbb)
                    rel = f"{w['median_ms'] / b['median_ms']:.2f}x ({delta:+.3f})"
                    nz = f"{nz_v:.3f}"
                    if kind == "mb":
                        ok = delta <= nz_v
                        gate = "pass" if ok else "**fail**"
                        if not ok:
                            fails.append(f"{n}:{m} {outputs} ({w['median_ms'] / b['median_ms']:.2f}x)")
                    else:
                        gate = "(reference)"
                print(f"| {label} | {outputs} | {w['median_ms']:.3f} [{w['min_ms']:.3f}..{w['max_ms']:.3f}] "
                      f"| {tlu:.3f} | {eu:.3f} | {script_ms(d, kind)} | {vis} / {hid} | {rel} | {nz} | {gate} |")
        print()
    print("Verdict: " + ("pass" if not fails else "fail at " + ", ".join(fails)))


if __name__ == "__main__":
    main()
