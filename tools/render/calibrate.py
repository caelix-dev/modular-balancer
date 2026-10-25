"""Calibrates the tier paint colours (tools/render/tiers.json) against vanilla (Plan 3 Task 4).

Target per tier: the median colour of the saturated paint pixels of the vanilla splitter (south
sheet, frame 1) and underground belt structure sprites of that tier (turbo from __space-age__),
averaged. Measured: the same statistic on a painted wall rendered under the scene's lights
(scene.py --calib). Each round scales the linear base colour by target / measured per channel.

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


def paint_median(img, box=None):
    a = np.array(img.convert("RGBA").crop(box) if box else img.convert("RGBA")).reshape(-1, 4).astype(float)
    a = a[a[:, 3] > 240][:, :3]
    mx, mn = a.max(1), a.min(1)
    sat = (mx - mn) / np.maximum(mx, 1)
    return np.median(a[(sat > 0.35) & (mx > 60)], 0)


def target(tier):
    s, u = SOURCES[tier]
    return (paint_median(Image.open(os.path.join(DATA, s)), (0, 0, 164, 64))
            + paint_median(Image.open(os.path.join(DATA, u)), (0, 0, 768, 384))) / 2


def lin(c):
    c = np.asarray(c) / 255.0
    return np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)


# the calibration wall's south face in the 384 px render (front face rows, inset from the edges)
FRONT = (110, 218, 274, 283)


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    path = os.path.join(HERE, "tiers.json")
    for r in range(rounds):
        subprocess.run([BLENDER, "-b", "--factory-startup", "--python", os.path.join(HERE, "scene.py"), "--", OUT,
                        "--quick", "--calib"], check=True, capture_output=True)
        tiers = json.load(open(path))
        for t in tiers:
            want = target(t)
            got = paint_median(Image.open(os.path.join(OUT, "calib-%s.png" % t)), FRONT)
            ratio = lin(want) / np.maximum(lin(got), 1e-4)
            tiers[t] = [round(float(min(1.0, v)), 4) for v in np.asarray(tiers[t]) * ratio]
            print(r, t, "want", want.astype(int), "got", got.astype(int), "->", tiers[t])
        json.dump(tiers, open(path, "w"), indent=1)


if __name__ == "__main__":
    main()
