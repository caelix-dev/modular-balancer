"""Packs the Blender renders (tools/render/scene.py) into the game's sprite sheets.

Run from the repo root:  python tools/render/pack.py [raw_dir]

For each block render it cuts away everything outside the block's tile on joined sides (the
neighbours' housing, modelled only so the outline bevels right), then downsamples the 3x
supersampled render to two sets:
  graphics/entity/balancer/hr/  64 px per tile (frames 128 px, used at scale 0.5)
  graphics/entity/balancer/lr/  32 px per tile (frames 64 px, used at scale 1)
with no extra blur (Lanczos only, as crisp as vanilla's HR sprites; shadows slightly blurred). Sheets: balancer-<tier>.png (47 frames,
8 per line, in the order of scripts/look.lua), machinery-<tier>.png (16 animation frames, 8 per
line), balancer-shadow.png, hood-<tier>.png and
hood-shadow.png (6 frames: hood on the N, E, S, W, N, E side), and icons balancer-<tier>.png.
"""

import os
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tools", "render", "out", "raw")
OUT = os.path.join(ROOT, "graphics", "entity", "balancer")
ICONS = os.path.join(ROOT, "graphics", "icons")

RES = 384  # raw frame (2 tiles, 192 px per tile)
PX = 192
TILE0, TILE1 = (RES - PX) // 2, (RES + PX) // 2  # the tile's footprint, columns and rows
LIFT = 75  # the housing top (0.55 high) shows 0.707 * 0.55 * 192 raw px above its footprint
FRAMES = 16  # machinery animation frames
TIERS = ["basic", "fast", "express", "turbo"]
SETS = {"hr": (128, 0.0), "lr": (64, 0.0)}  # frame px, blur radius (none: as crisp as vanilla HR)
SHADOW_BLUR = {"hr": 0.9, "lr": 0.6}

N, E, S, W, NE, SE, SW, NW = 1, 2, 4, 8, 16, 32, 64, 128


def masks():
    out = []
    for m in range(256):
        c = m & 15
        for bit, a, b in ((NE, N, E), (SE, E, S), (SW, S, W), (NW, W, N)):
            if m & a and m & b:
                c |= m & bit
        if c == m:
            out.append(m)
    return out


def load(name):
    return Image.open(os.path.join(RAW, name)).convert("RGBA")


def clip(img, mask):
    a = np.array(img)
    if mask & W:
        a[:, :TILE0] = 0
    if mask & E:
        a[:, TILE1:] = 0
    if mask & N:
        a[:TILE0 - LIFT, :] = 0
    if mask & S:
        a[TILE1 - LIFT:, :] = 0
    return Image.fromarray(a, "RGBA")


def outline(img, strength=0.55):
    """Darkens the outermost pixels of the silhouette, like the dark rim vanilla sprites have."""
    import numpy as np
    from PIL import ImageFilter as F
    a = img.getchannel("A")
    inner = a.filter(F.MinFilter(3))
    rim = np.clip((np.asarray(a, float) - np.asarray(inner, float)) / 255.0, 0, 1)
    rgb = np.asarray(img.convert("RGB"), float) * (1 - strength * rim[..., None])
    out = Image.fromarray(rgb.clip(0, 255).astype("uint8"), "RGB")
    out.putalpha(a)
    return out


def shrink(img, size, blur):
    pre = img.convert("RGBa").resize((size, size), Image.LANCZOS)
    if blur:
        pre = pre.filter(ImageFilter.GaussianBlur(blur))
    return pre.convert("RGBA")


def shadow(img):
    """Black with the shadow catcher's alpha."""
    a = img.getchannel("A")
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.putalpha(a)
    return out


def sheet(frames, per_line, size):
    rows = (len(frames) + per_line - 1) // per_line
    out = Image.new("RGBA", (size * per_line, size * rows), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        out.paste(f, ((i % per_line) * size, (i // per_line) * size))
    return out


def main():
    ms = masks()
    assert len(ms) == 47
    order = ["n", "e", "s", "w", "n", "e"]
    block_shadow = shadow(load("block-shadow.png"))
    hood_shadow = {s: shadow(load("hood-shadow-%s.png" % s)) for s in "nesw"}
    raw_blocks = {(t, m): clip(load("block-%s-%03d.png" % (t, m)), m) for t in TIERS for m in ms}
    raw_hoods = {(t, s): load("hood-%s-%s.png" % (t, s)) for t in TIERS for s in "nesw"}
    raw_anim = {(t, f): load("anim-%s-%02d.png" % (t, f)) for t in TIERS for f in range(FRAMES)}
    for key, (size, blur) in SETS.items():
        d = os.path.join(OUT, key)
        os.makedirs(d, exist_ok=True)
        bs = shrink(block_shadow, size, SHADOW_BLUR[key])
        sheet([bs] * len(ms), 8, size).save(os.path.join(d, "balancer-shadow.png"), optimize=True)
        hs = {s: shrink(hood_shadow[s], size, SHADOW_BLUR[key]) for s in "nesw"}
        sheet([hs[s] for s in order], 6, size).save(os.path.join(d, "hood-shadow.png"), optimize=True)
        for t in TIERS:
            sheet([outline(shrink(raw_blocks[(t, m)], size, blur)) for m in ms], 8, size).save(
                os.path.join(d, "balancer-%s.png" % t), optimize=True)
            sheet([shrink(raw_anim[(t, f)], size, blur) for f in range(FRAMES)], 8, size).save(
                os.path.join(d, "machinery-%s.png" % t), optimize=True)
            h = {s: outline(shrink(raw_hoods[(t, s)], size, blur)) for s in "nesw"}
            sheet([h[s] for s in order], 6, size).save(os.path.join(d, "hood-%s.png" % t), optimize=True)
    # icons: a lone block with an input hood above and an output hood below
    os.makedirs(ICONS, exist_ok=True)
    for t in TIERS:
        scene = Image.new("RGBA", (RES, RES + 2 * PX), (0, 0, 0, 0))
        scene.alpha_composite(raw_hoods[(t, "s")], (0, 0))
        scene.alpha_composite(raw_blocks[(t, 0)], (0, PX))
        scene.alpha_composite(raw_anim[(t, 0)], (0, PX))
        scene.alpha_composite(raw_hoods[(t, "n")], (0, 2 * PX))
        icon = scene.crop(scene.getbbox())
        k = 62 / max(icon.size)
        icon = icon.convert("RGBa").resize((max(1, round(icon.size[0] * k)), max(1, round(icon.size[1] * k))),
                                           Image.LANCZOS).convert("RGBA")
        canvas = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        canvas.alpha_composite(icon, ((64 - icon.size[0]) // 2, (64 - icon.size[1]) // 2))
        canvas.save(os.path.join(ICONS, "balancer-%s.png" % t), optimize=True)
    print("packed")


if __name__ == "__main__":
    main()
