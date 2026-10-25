"""Starting values for the paint and steel colours (tools/render/tiers.json), Plan 3 Task 4.

Compares like with like: the LIT surfaces only. For each tier, the paint pixels (saturated) of the
vanilla splitter (south sheet, frame 1) and underground belt structure (turbo from __space-age__)
are reduced to the mean of their 70th-90th luminance percentile band (lit, unworn paint; no
shadowed faces, crevices or highlights), and the same statistic is taken on our rendered block
(scene.py --calib renders a lone block per tier). Each round scales the linear base colours by
target / measured per channel. Steel is only reported: our steel top is one flat lit plate, so its
statistic is not comparable with vanilla's mixed housing; tiers.json "steel" is set by eye.

These numbers are only a starting point: the final judgement is visual, in game, our block next to
the vanilla splitter of the same tier at default zoom and 2x (adjust tiers.json by hand from there).

Run from the repo root:  python tools/render/calibrate.py [rounds]
"""

import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = r"E:\factorio-dev\2.1.23\Factorio\data"
BLENDER = r"E:\Blender\blender-5.2.3-windows-x64\blender.exe"
OUT = os.path.join(HERE, "out", "calib")

SOURCES = {
    "basic": ["base/graphics/entity/splitter/splitter-south.png",
              "base/graphics/entity/underground-belt/underground-belt-structure.png"],
    "fast": ["base/graphics/entity/fast-splitter/fast-splitter-south.png",
             "base/graphics/entity/fast-underground-belt/fast-underground-belt-structure.png"],
    "express": ["base/graphics/entity/express-splitter/express-splitter-south.png",
                "base/graphics/entity/express-underground-belt/express-underground-belt-structure.png"],
    "turbo": ["space-age/graphics/entity/turbo-splitter/turbo-splitter-south.png",
              "space-age/graphics/entity/turbo-underground-belt/turbo-underground-belt-structure.png"],
}
STEEL_SOURCES = [("base/graphics/entity/splitter/splitter-north.png", (0, 0, 160, 70)),
                 ("base/graphics/entity/fast-splitter/fast-splitter-north.png", (0, 0, 160, 70))]


def pixels(img, box=None):
    a = np.array((img.crop(box) if box else img).convert("RGBA")).reshape(-1, 4).astype(float)
    return a[a[:, 3] > 240][:, :3]


def lit(a, paint):
    """Mean of the 70-90th luminance percentile band of the paint (saturated) or steel (grey) pixels."""
    mx, mn = a.max(1), a.min(1)
    sat = (mx - mn) / np.maximum(mx, 1)
    a = a[(sat > 0.35) & (mx > 50)] if paint else a[(sat < 0.18) & (mx > 30)]
    lum = a @ np.array([0.2126, 0.7152, 0.0722])
    lo, hi = np.percentile(lum, 70), np.percentile(lum, 90)
    return a[(lum >= lo) & (lum <= hi)].mean(0)


def lin(c):
    c = np.asarray(c) / 255.0
    return np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    path = os.path.join(HERE, "tiers.json")
    want_steel = np.mean([lit(pixels(Image.open(os.path.join(DATA, f)), b), False) for f, b in STEEL_SOURCES], 0)
    for r in range(rounds):
        subprocess.run([BLENDER, "-b", "--factory-startup", "--python", os.path.join(HERE, "scene.py"), "--", OUT,
                        "--quick", "--calib"], check=True, capture_output=True)
        tiers = json.load(open(path))
        steel = tiers.get("steel", [0.10, 0.095, 0.088])
        got_steel = []
        for t in SOURCES:
            s, u = SOURCES[t]
            want = (lit(pixels(Image.open(os.path.join(DATA, s)), (0, 0, 164, 64)), True)
                    + lit(pixels(Image.open(os.path.join(DATA, u)), (0, 0, 768, 384)), True)) / 2
            ours = pixels(Image.open(os.path.join(OUT, "calib-%s.png" % t)))
            got = lit(ours, True)
            got_steel.append(lit(ours, False))
            tiers[t] = [round(float(min(1.0, v)), 4)
                        for v in np.asarray(tiers[t]) * lin(want) / np.maximum(lin(got), 1e-4)]
            print(r, t, "vanilla lit paint", want.astype(int), "ours", got.astype(int))
        print(r, "steel (set by hand: our flat steel top against vanilla's housing median): vanilla",
              want_steel.astype(int), "ours", np.mean(got_steel, 0).astype(int))
        json.dump(tiers, open(path, "w"), indent=1)


if __name__ == "__main__":
    main()
