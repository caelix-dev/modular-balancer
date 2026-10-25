"""Generates the balancer block and port hood sprites (Plan 3 Task 4).

Original art drawn procedurally with Pillow + numpy, in Factorio's rendered style: top-down with
a slight 3/4 tilt, light from the upper left, a separate shadow layer cast to the lower right,
weathered dark steel with bevels, rivets and grime, tier colour on the front face and the
inner lanes. HR resolution: 64 px per tile, used at scale 0.5.

Run from the repo root:  python tools/gen_sprites.py
Writes graphics/entity/balancer/*.png and graphics/icons/balancer-*.png (committed).

Block sheet (per tier): 47 frames of FRAME x FRAME px, 8 per line, one per connected
neighbourhood in the order of scripts/look.lua (`look.masks()`): side bits N=1 E=2 S=4 W=8,
corner bits NE=16 SE=32 SW=64 NW=128, a corner bit kept only when both its sides are set.
The tile sits at (PAD_X, PAD_Y) in each frame; the front face and the shadow hang below/right.

Hood sheet (per tier): 6 frames of FRAME x FRAME px, the port hood on the N, E, S, W, N, E side
of the edge tile (the side facing the block); the tile sits in the middle of the frame. Linked
belt `direction_in` uses frames 1-4, `direction_out` frames 3-6.
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

T = 64  # HR px per tile
SS = 4  # supersampling
FRAME = 96
PAD_X, PAD_Y = 16, 4  # tile position in a block frame
HOOD_PAD = 16  # tile position in a hood frame
FACE = 22  # front face height
RIM = 7  # raised rim width
SHADOW_DX, SHADOW_DY = 17, 6

# "steel": dark steel housing with tier-coloured trim (default, shipped); "painted": the housing
# top painted in the tier colour like the vanilla splitter. `python tools/gen_sprites.py painted`
STYLE = "steel"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "graphics", "entity", "balancer")
ICONS = os.path.join(ROOT, "graphics", "icons")

TIERS = {
    "basic": (222, 168, 62),
    "fast": (214, 62, 50),
    "express": (64, 158, 206),
    "turbo": (140, 186, 52),
}

STEEL = np.array((96, 90, 82), float)
STEEL_RIM = np.array((124, 117, 107), float)
STEEL_DARK = np.array((44, 42, 40), float)
HIGHLIGHT = np.array((176, 170, 160), float)
SHADE = np.array((24, 22, 21), float)
RUBBER = np.array((52, 48, 46), float)
HOLE = np.array((14, 13, 12), float)

N, E, S, W, NE, SE, SW, NW = 1, 2, 4, 8, 16, 32, 64, 128


def masks():
    out = []
    for m in range(256):
        c = m & 15
        if m & N and m & E:
            c |= m & NE
        if m & E and m & S:
            c |= m & SE
        if m & S and m & W:
            c |= m & SW
        if m & W and m & N:
            c |= m & NW
        if c == m:
            out.append(m)
    return out


# ---------------------------------------------------------------- canvas helpers (SS space)


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.rgb = np.zeros((h * SS, w * SS, 3), float)
        self.a = np.zeros((h * SS, w * SS), float)

    def put(self, mask, rgb):
        """Paints colour `rgb` (3-vector or HxWx3) through coverage `mask` (HxW, 0..1)."""
        a = mask[..., None]
        self.rgb = self.rgb * (1 - a) + np.broadcast_to(rgb, self.rgb.shape) * a
        self.a = self.a * (1 - mask) + mask

    def shade(self, mask, factor):
        """Multiplies existing colour by `factor` through `mask` (darken < 1 < lighten)."""
        f = 1 + (factor - 1) * mask
        self.rgb = self.rgb * f[..., None]

    def image(self):
        a = np.clip(self.a, 0, 1)
        pre = np.clip(self.rgb, 0, 255) * a[..., None]
        img = np.dstack([pre, a * 255]).astype(np.float32)
        h, w = self.h, self.w
        img = img.reshape(h, SS, w, SS, 4).mean(axis=(1, 3))
        alpha = img[..., 3:4]
        rgb = np.where(alpha > 0, img[..., :3] / np.maximum(alpha, 1e-6) * 255, 0)
        out = np.dstack([rgb, alpha]).clip(0, 255).astype(np.uint8)
        return Image.fromarray(out, "RGBA")


def mask_of(w, h, draw_fn):
    im = Image.new("L", (w * SS, h * SS), 0)
    draw_fn(ImageDraw.Draw(im), SS)
    return np.asarray(im, float) / 255


def rect(w, h, x0, y0, x1, y1, r=0):
    return mask_of(w, h, lambda d, k: d.rounded_rectangle(
        (x0 * k, y0 * k, x1 * k - 1, y1 * k - 1), radius=r * k, fill=255))


def poly(w, h, pts):
    return mask_of(w, h, lambda d, k: d.polygon([(x * k, y * k) for x, y in pts], fill=255))


def ellipse(w, h, x0, y0, x1, y1):
    return mask_of(w, h, lambda d, k: d.ellipse((x0 * k, y0 * k, x1 * k - 1, y1 * k - 1), fill=255))


# ---------------------------------------------------------------- noise (tile-periodic)

_rng = np.random.default_rng(20261025)


def periodic_noise(size, sigma):
    """Noise of period `size` (SS px), low-passed with a Gaussian of `sigma` SS px, in -1..1."""
    white = _rng.standard_normal((size, size))
    f = np.fft.fft2(white)
    ky = np.fft.fftfreq(size)[:, None]
    kx = np.fft.fftfreq(size)[None, :]
    g = np.exp(-2 * (math.pi * sigma) ** 2 * (kx ** 2 + ky ** 2))
    n = np.real(np.fft.ifft2(f * g))
    n -= n.mean()
    return n / (np.abs(n).max() + 1e-9)


P = T * SS
FINE = periodic_noise(P, 0.8)
GRIME = periodic_noise(P, 18)
BLOTCH = periodic_noise(P, 6)
STREAK = np.repeat(periodic_noise(P, 2)[:, :1], P, axis=1) * 0.5 + periodic_noise(P, 1.2) * 0.5


def field(canvas, ox, oy, base, fine=7, grime=14, blotch=6, streak=3):
    """A steel colour field over the whole canvas, periodic with the tile grid (tile origin at
    ox, oy HR px), so joined tiles continue seamlessly."""
    hh, ww = canvas.h * SS, canvas.w * SS
    ys = (np.arange(hh) - oy * SS) % P
    xs = (np.arange(ww) - ox * SS) % P
    n = (FINE[np.ix_(ys, xs)] * fine + GRIME[np.ix_(ys, xs)] * grime
         + BLOTCH[np.ix_(ys, xs)] * blotch + STREAK[np.ix_(ys, xs)] * streak)
    warm = np.array((1.0, 0.97, 0.93))
    return np.clip(base[None, None, :] + n[..., None] * warm, 0, 255)


def paint_field(canvas, ox, oy, color):
    col = np.array(color, float)
    f = field(canvas, ox, oy, col * 0.9, fine=7, grime=34, blotch=14, streak=5)
    return f


# ---------------------------------------------------------------- parts


def rivet(c, x, y, r=1.6):
    w, h = c.w, c.h
    c.put(ellipse(w, h, x - r, y - r + 0.6, x + r, y + r + 0.6), SHADE)
    c.put(ellipse(w, h, x - r, y - r, x + r, y + r), np.array((122, 117, 110), float))
    c.put(ellipse(w, h, x - r * 0.75, y - r * 0.8, x + r * 0.2, y + r * 0.1), HIGHLIGHT)


def line(c, x0, y0, x1, y1, color, alpha=1.0, width=1.0):
    m = mask_of(c.w, c.h, lambda d, k: d.line((x0 * k, y0 * k, x1 * k, y1 * k), fill=255,
                                              width=max(1, int(width * k))))
    c.put(m * alpha, np.array(color, float))


def lane(c, a, b, width, clip, tier, chevrons=(0.3, 0.7), shadow=False):
    """A short belt lane from a to b (HR px) clipped to `clip`: rubber with treads and bright
    tier-coloured chevrons pointing from a to b, like the vanilla belt arrows."""
    w, h = c.w, c.h
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    ln = math.hypot(dx, dy)
    ux, uy = dx / ln, dy / ln
    nx, ny = -uy * width / 2, ux * width / 2
    pts = [(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)]
    if shadow:
        c.put(poly(w, h, [(px + 2, py + 2) for px, py in pts]) * clip * 0.7, SHADE)
    m = poly(w, h, pts) * clip
    c.put(m, RUBBER)
    # side rails of the lane
    for sgn in (1, -1):
        e0 = (ax + nx * sgn, ay + ny * sgn)
        e1 = (bx + nx * sgn, by + ny * sgn)
        line(c, e0[0], e0[1], e1[0], e1[1], (110, 104, 96) if sgn > 0 else (30, 28, 26), 0.9, 1.0)
    steps = int(ln / 3.2)
    for i in range(1, steps):
        t = i / steps
        px, py = ax + dx * t, ay + dy * t
        line(c, px + nx * 0.85, py + ny * 0.85, px - nx * 0.85, py - ny * 0.85, (32, 29, 28), 0.85, 0.7)
    col = np.array(TIERS[tier], float)
    for t in chevrons:
        px, py = ax + dx * t, ay + dy * t
        tip = (px + ux * 3.2, py + uy * 3.2)
        l1 = (px - ux * 1.6 + nx * 0.8, py - uy * 1.6 + ny * 0.8)
        l2 = (px - ux * 1.6 - nx * 0.8, py - uy * 1.6 - ny * 0.8)
        back = (px + ux * 0.6, py + uy * 0.6)
        cm = poly(w, h, [l1, tip, l2, back]) * clip
        c.put(cm, col)
        inner = poly(w, h, [((l1[0] + px) / 2, (l1[1] + py) / 2), ((tip[0] + px) / 2, (tip[1] + py) / 2),
                            ((l2[0] + px) / 2, (l2[1] + py) / 2)]) * clip
        c.put(inner * 0.6, np.minimum(col * 1.35 + 30, 255))


def bay(c, x0, y0, x1, y1, tier):
    """The recessed bay in a block's top: two belt lanes crossing (X) around a diverter hub,
    the far (north) inner wall visible in the 3/4 view."""
    w, h = c.w, c.h
    hole = rect(w, h, x0, y0, x1, y1, 3)
    c.put(hole, HOLE)
    floor = rect(w, h, x0 + 1, y0 + 4, x1 - 1, y1 - 1, 2)
    cx, cy = (x0 + x1) / 2, (y0 + y1 + 4) / 2
    # two lanes crossing, the lower one first
    lane(c, (x1 + 2, y0 + 1), (x0 - 2, y1 + 2), 13, floor, tier, chevrons=(0.2, 0.8))
    lane(c, (x0 - 2, y0 + 1), (x1 + 2, y1 + 2), 13, floor, tier, chevrons=(0.2, 0.8), shadow=True)
    # diverter hub where they cross
    r = 6.5
    c.put(ellipse(w, h, cx - r + 1.5, cy - r + 2, cx + r + 1.5, cy + r + 2) * 0.7, SHADE)
    c.put(ellipse(w, h, cx - r, cy - r, cx + r, cy + r), np.array((96, 92, 86), float))
    ys = np.arange(h * SS)[:, None] / SS
    xs = np.arange(w * SS)[None, :] / SS
    d = ((xs - (cx - 2)) ** 2 + (ys - (cy - 2)) ** 2) ** 0.5 / (r * 1.6)
    hub = ellipse(w, h, cx - r, cy - r, cx + r, cy + r)
    c.shade(hub * np.clip(1 - d, 0, 1), 1.7)
    c.put(ellipse(w, h, cx - 2.2, cy - 2.2, cx + 2.2, cy + 2.2), np.array((40, 38, 36), float))
    c.put(ellipse(w, h, cx - 1.2, cy - 1.6, cx + 0.6, cy + 0.2), np.array(TIERS[tier], float))
    # far inner wall (faces the viewer, away from the light)
    wall = rect(w, h, x0, y0, x1, y0 + 4.5, 3)
    c.put(wall, field(c, 0, 0, np.array((44, 42, 39), float), fine=5, grime=6))
    c.put(rect(w, h, x0, y0 + 3.8, x1, y0 + 4.8) * 0.9, SHADE)
    c.put(rect(w, h, x0, y0 + 4, x0 + 1.6, y1) * 0.85, SHADE)
    c.put(rect(w, h, x1 - 1.4, y0 + 4, x1, y1) * 0.5, np.array((120, 114, 106), float))
    c.put(rect(w, h, x0 + 1, y1 - 0.6, x1 - 1, y1 + 0.8, 1) * 0.85, np.array((176, 170, 158), float))
    for bx, by in ((x0 - 3, y0 - 3), (x1 + 3, y0 - 3), (x0 - 3, y1 + 3), (x1 + 3, y1 + 3)):
        rivet(c, bx, by, 1.5)


def face(c, x0, x1, y0, tier, ox, cap_l, cap_r, slot=None):
    """Front face from x0 to x1 (HR px), top at y0, FACE px tall: a dark steel kick strip and a
    tier-coloured painted panel, like the vanilla splitter's front."""
    w, h = c.w, c.h
    y1 = y0 + FACE
    m = rect(w, h, x0, y0 - 6, x1, y1, 4 if (cap_l or cap_r) else 0)
    if not cap_l:
        m = np.maximum(m, rect(w, h, x0, y0 - 6, x0 + 8, y1))
    if not cap_r:
        m = np.maximum(m, rect(w, h, x1 - 8, y0 - 6, x1, y1))
    m = m * rect(w, h, x0, y0, x1, y1)
    col = paint_field(c, ox, 0, TIERS[tier])
    yy = (np.arange(h * SS) / SS - y0) / FACE
    grad = np.clip(1.18 - 0.5 * yy, 0.55, 1.2)[:, None, None]
    c.put(m, col * grad)
    # top lip in steel (the rim's front edge), lit
    lip = m * rect(w, h, x0, y0, x1, y0 + 2)
    c.put(lip, field(c, ox, 0, np.array((112, 107, 100), float), fine=5, grime=8))
    c.put(lip * rect(w, h, x0, y0 + 1.4, x1, y0 + 2), SHADE)
    # dark steel kick strip at the bottom
    kick = m * rect(w, h, x0, y1 - 3.5, x1, y1)
    c.put(kick, field(c, ox, 0, np.array((46, 44, 41), float), fine=5, grime=8))
    c.put(kick * rect(w, h, x0, y1 - 3.5, x1, y1 - 2.8) * 0.5, SHADE)
    c.put(m * rect(w, h, x0, y1 - 1.2, x1, y1) * 0.9, np.array((16, 15, 14), float))
    # paint wear: lighter scratches and darker drips
    rnd = random.Random(int(ox * 7 + y0 * 13 + x0))
    for _ in range(int((x1 - x0) / 7)):
        sx = rnd.uniform(x0 + 2, x1 - 4)
        sy = rnd.uniform(y0 + 4, y1 - 7)
        line(c, sx, sy, sx + rnd.uniform(1, 4), sy + rnd.uniform(-0.6, 0.6), (225, 214, 190), 0.22, 0.5)
    for _ in range(int((x1 - x0) / 12)):
        sx = rnd.uniform(x0 + 2, x1 - 2)
        line(c, sx, y0 + 3, sx + rnd.uniform(-0.3, 0.3), y0 + 3 + rnd.uniform(3, 8), (20, 16, 12), 0.18, 0.8)
    for gx in range(int(x0), int(x1)):
        if (gx - ox) % T == 32 and x0 + 3 < gx < x1 - 3:
            line(c, gx, y0 + 3, gx, y1 - 5, (30, 26, 22), 0.75, 0.8)
            line(c, gx + 1, y0 + 3, gx + 1, y1 - 5, (255, 240, 210), 0.15, 0.6)
        if (gx - ox) % T in (12, 52) and x0 + 4 < gx < x1 - 4:
            rivet(c, gx, y0 + 7.5, 1.4)
    if cap_l:
        c.put(m * rect(w, h, x0, y0, x0 + 1.6, y1), np.array((255, 240, 210), float) * 0.5)
    if cap_r:
        c.put(m * rect(w, h, x1 - 2, y0, x1, y1), np.array((18, 16, 14), float))
    if slot is not None:
        mouth(c, slot[0], slot[1], y0 + 3, y1, "s")


def mouth(c, x0, x1, y0, y1, facing):
    """A dark belt opening with a roller at the top and rubber flaps hanging in it."""
    w, h = c.w, c.h
    hole = rect(w, h, x0, y0, x1, y1, 2)
    c.put(hole, HOLE)
    if facing == "s":
        roll = rect(w, h, x0 + 1, y0 + 0.5, x1 - 1, y0 + 4.5, 2)
        yy = (np.arange(h * SS) / SS - (y0 + 0.5)) / 4
        rg = np.clip(1.05 - np.abs(yy - 0.3) * 1.5, 0.15, 1.05)[:, None, None]
        c.put(roll, np.array((150, 146, 138), float) * rg)
        n = max(3, int((x1 - x0) / 5))
        for i in range(n):
            fx0 = x0 + 1.5 + i * (x1 - x0 - 3) / n
            fx1 = fx0 + (x1 - x0 - 3) / n - 0.8
            flap = rect(w, h, fx0, y0 + 4.5, fx1, y1 - 2.5, 0.5)
            c.put(flap, np.array((40, 37, 35), float))
            c.put(flap * rect(w, h, fx0, y0 + 4.5, fx0 + 0.8, y1) * 0.6, np.array((90, 86, 80), float))


def plate(c, region, ox, oy, cyl=None):
    """Steel plate; `cyl` = (axis 'x'|'y', a0, a1) shades it like a rounded cowling."""
    col = field(c, ox, oy, STEEL)
    if cyl:
        axis, a0, a1 = cyl
        coord = (np.arange(c.w * SS) / SS)[None, :] if axis == "x" else (np.arange(c.h * SS) / SS)[:, None]
        t = np.clip((coord - a0) / (a1 - a0), 0, 1)
        k = 0.78 + 0.55 * np.sin(np.pi * np.clip(t * 0.85 + 0.05, 0, 1)) - 0.25 * t
        col = col * k[..., None] if k.ndim == 2 else col * k[..., None]
    c.put(region, col)


def ao(c, region, x0, y0, x1, y1, sides, depth=5):
    """Ambient occlusion: darkens the plate next to the raised rims."""
    w, h = c.w, c.h
    ys = np.arange(h * SS)[:, None] / SS
    xs = np.arange(w * SS)[None, :] / SS
    d = np.full((h * SS, w * SS), 99.0)
    if "n" in sides:
        d = np.minimum(d, ys - (y0 + RIM))
    if "s" in sides:
        d = np.minimum(d, (y1 - RIM) - ys)
    if "w" in sides:
        d = np.minimum(d, xs - (x0 + RIM))
    if "e" in sides:
        d = np.minimum(d, (x1 - RIM) - xs)
    k = np.clip(1 - d / depth, 0, 1) * (d > -0.5)
    c.shade(region * k * 0.9, 0.62)


def rims(c, x0, y0, x1, y1, sides, corners_open, ox, oy, rivets=True, band_tier=None):
    """Raised, chamfered rim along the open `sides` ('n','e','s','w') of the box x0..x1, y0..y1,
    plus the inner corner pieces in `corners_open` ('ne', ...). With `band_tier`, the north rim
    carries the tier colour band (like the vanilla splitter's top)."""
    w, h = c.w, c.h
    band = np.zeros((h * SS, w * SS))
    parts = {}
    if "n" in sides:
        parts["n"] = rect(w, h, x0, y0, x1, y0 + RIM)
    if "s" in sides:
        parts["s"] = rect(w, h, x0, y1 - RIM, x1, y1)
    if "w" in sides:
        parts["w"] = rect(w, h, x0, y0, x0 + RIM, y1)
    if "e" in sides:
        parts["e"] = rect(w, h, x1 - RIM, y0, x1, y1)
    for p in parts.values():
        band = np.maximum(band, p)
    for cn in corners_open:
        cx = x1 - RIM if "e" in cn else x0
        cy = y1 - RIM if "s" in cn else y0
        band = np.maximum(band, rect(w, h, cx, cy, cx + RIM, cy + RIM))
    band = band * c.a
    c.put(band, field(c, ox, oy, STEEL_RIM, fine=6, grime=12))
    if band_tier and "n" in parts:
        nb = parts["n"] * c.a * rect(w, h, x0 + (RIM if "w" in parts else 0) - 0.01, y0 + 1.0,
                                     x1 - (RIM if "e" in parts else 0) + 0.01, y0 + RIM - 0.8)
        c.put(nb, paint_field(c, ox, oy, TIERS[band_tier]) * 1.05)
    # chamfer shading across each rim: outer half lit or dark by facing
    ys = np.arange(h * SS)[:, None] / SS
    xs = np.arange(w * SS)[None, :] / SS
    if "n" in parts:
        t = np.clip((ys - y0) / RIM, 0, 1)
        c.shade(parts["n"] * c.a, 1.0)
        c.shade(parts["n"] * c.a * (1 - t) * 0.9, 1.45)
    if "w" in parts:
        t = np.clip((xs - x0) / RIM, 0, 1)
        c.shade(parts["w"] * c.a * (1 - t) * 0.8, 1.35)
    if "s" in parts:
        t = np.clip((y1 - ys) / RIM, 0, 1)
        c.shade(parts["s"] * c.a * (1 - t) * 0.6, 0.7)
    if "e" in parts:
        t = np.clip((x1 - xs) / RIM, 0, 1)
        c.shade(parts["e"] * c.a * (1 - t) * 0.9, 0.6)

    def edge(x_0, y_0, x_1, y_1, color, alpha):
        c.put(rect(w, h, x_0, y_0, x_1, y_1) * band * alpha, np.array(color, float))
    lit, dark = (200, 194, 180), (24, 22, 20)
    if "n" in parts:
        edge(x0, y0, x1, y0 + 1.0, lit, 0.9)
        edge(x0 + (RIM if "w" in parts else 0), y0 + RIM - 1, x1 - (RIM if "e" in parts else 0), y0 + RIM, dark, 0.8)
    if "s" in parts:
        edge(x0 + (RIM if "w" in parts else 0), y1 - RIM, x1 - (RIM if "e" in parts else 0), y1 - RIM + 1, lit, 0.55)
    if "w" in parts:
        edge(x0, y0, x0 + 1.0, y1, lit, 0.8)
        edge(x0 + RIM - 1, y0 + (RIM if "n" in parts else 0), x0 + RIM, y1 - (RIM if "s" in parts else 0), dark, 0.7)
    if "e" in parts:
        edge(x1 - 1.2, y0, x1, y1, dark, 0.95)
        edge(x1 - RIM, y0 + (RIM if "n" in parts else 0), x1 - RIM + 1, y1 - (RIM if "s" in parts else 0), lit, 0.4)
    for cn in corners_open:
        cx = x1 - RIM if "e" in cn else x0
        cy = y1 - RIM if "s" in cn else y0
        if "n" in cn:
            edge(cx, cy, cx + RIM, cy + 1.0, lit, 0.85)
        else:
            edge(cx, cy + RIM - 1.0, cx + RIM, cy + RIM, dark, 0.8)
        if "w" in cn:
            edge(cx, cy, cx + 1.0, cy + RIM, lit, 0.75)
        else:
            edge(cx + RIM - 1.2, cy, cx + RIM, cy + RIM, dark, 0.85)
    if rivets:
        for s in parts:
            if s in "ns":
                yy = y0 + RIM / 2 if s == "n" else y1 - RIM / 2
                for xx in range(int(x0), int(x1) + 1):
                    if (xx - ox) % 16 == 8 and x0 + 3 < xx < x1 - 3:
                        if not (band_tier and s == "n"):
                            rivet(c, xx, yy, 1.3)
            else:
                xx = x0 + RIM / 2 if s == "w" else x1 - RIM / 2
                for yy in range(int(y0), int(y1) + 1):
                    if (yy - oy) % 16 == 8 and y0 + 3 < yy < y1 - 3:
                        rivet(c, xx, yy, 1.3)


# ---------------------------------------------------------------- block frames


def silhouette(x0, y0, x1, y1, round_corners, r=6):
    top = rect(FRAME, FRAME, x0, y0, x1, y1)
    for cx, cy in round_corners:
        sx = 1 if cx == x0 else -1
        sy = 1 if cy == y0 else -1
        corner = rect(FRAME, FRAME, min(cx, cx + sx * r), min(cy, cy + sy * r), max(cx, cx + sx * r), max(cy, cy + sy * r))
        disc = ellipse(FRAME, FRAME, cx + sx * r - r, cy + sy * r - r, cx + sx * r + r, cy + sy * r + r)
        top = top * (1 - corner) + corner * disc * top
    return top


def corner_plates(c, x0, y0, x1, y1):
    """Four slightly raised triangular plates in the tile's corners around the bay, with a bolt
    each: breaks up the flat top (periodic with the tile, so joined tiles stay seamless)."""
    w, h = c.w, c.h
    k = 15
    for cx, cy, sx, sy in ((x0 + 6, y0 + 6, 1, 1), (x1 - 6, y0 + 6, -1, 1), (x0 + 6, y1 - 8, 1, -1), (x1 - 6, y1 - 8, -1, -1)):
        pts = [(cx, cy), (cx + sx * k, cy), (cx, cy + sy * k)]
        m = poly(w, h, pts) * c.a
        c.put(poly(w, h, [(px + 0.8, py + 1.0) for px, py in pts]) * c.a * 0.5, SHADE)
        c.put(m, field(c, x0, y0, STEEL * 1.08, fine=6, grime=10))
        c.put(m * poly(w, h, [(cx, cy), (cx + sx * k, cy), (cx + sx * (k - 1.2), cy + sy * 1.0), (cx + sy * 0, cy + sy * 1.0)]) * 0.5,
              np.array((190, 182, 168), float))
        rivet(c, cx + sx * 4.5, cy + sy * 4.5, 1.3)


def block_frame(mask, tier):
    c = Canvas(FRAME, FRAME)
    x0, y0 = PAD_X, PAD_Y
    x1, y1 = x0 + T, y0 + T
    j = {s: bool(mask & b) for s, b in (("n", N), ("e", E), ("s", S), ("w", W))}
    rc = []
    for cx, cy, a, b in ((x0, y0, "n", "w"), (x1, y0, "n", "e"), (x0, y1, "s", "w"), (x1, y1, "s", "e")):
        if not j[a] and not j[b]:
            rc.append((cx, cy))
    top = silhouette(x0, y0, x1, y1, rc)
    if STYLE == "painted":
        c.put(top, field(c, x0, y0, np.array(TIERS[tier], float) * 0.74, fine=6, grime=18, blotch=8, streak=4))
    else:
        plate(c, top, x0, y0)
    open_sides = [s for s in "nesw" if not j[s]]
    ao(c, top, x0, y0, x1, y1, open_sides)
    corner_plates(c, x0, y0, x1, y1)
    bay(c, x0 + 10, y0 + 9, x1 - 10, y1 - 11, tier)
    inner = []
    for cn, a, b, bit in (("ne", "n", "e", NE), ("se", "s", "e", SE), ("sw", "s", "w", SW), ("nw", "n", "w", NW)):
        if j[a] and j[b] and not mask & bit:
            inner.append(cn)
    rims(c, x0, y0, x1, y1, open_sides, inner, x0, y0, band_tier=tier)
    if not j["s"]:
        face(c, x0, x1, y1, tier, x0, not j["w"], not j["e"])
    return c.image()


def block_shadow(mask):
    c = Canvas(FRAME, FRAME)
    x0, y0 = PAD_X, PAD_Y
    j_s = bool(mask & S)
    bottom = y0 + T + (0 if j_s else FACE)
    m = rect(FRAME, FRAME, x0 + SHADOW_DX, y0 + SHADOW_DY, x0 + T + SHADOW_DX, bottom + SHADOW_DY, 5)
    c.put(m, np.zeros(3))
    img = c.image()
    a = img.getchannel("A").filter(ImageFilter.GaussianBlur(1.8))
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.putalpha(a.point(lambda v: int(v * 1.0)))
    return out


# ---------------------------------------------------------------- hoods


def cowl_shade(c, region, axis, a0, a1):
    """Shades `region` like a rounded cowling whose axis runs along the belt: brightest a third
    of the way across (light from the upper left), dark at the far edge."""
    coord = (np.arange(c.w * SS) / SS)[None, :] if axis == "x" else (np.arange(c.h * SS) / SS)[:, None]
    t = np.clip((coord - a0) / (a1 - a0), 0, 1)
    k = 0.78 + 0.42 * np.sin(np.pi * np.clip(t * 0.9 + 0.08, 0, 1)) ** 0.8 - 0.25 * t
    c.rgb = c.rgb * (1 + (np.broadcast_to(k, region.shape) - 1) * region)[..., None]
    # specular streak
    spec = np.exp(-((t - 0.3) / 0.06) ** 2)
    c.put(region * np.broadcast_to(spec, region.shape) * 0.35, np.array((220, 214, 200), float))


def tier_band(c, m, tier, ox, oy):
    """The steel lip at a cowl's mouth (contrasts with the cowl's tier paint)."""
    c.put(m, field(c, ox, oy, STEEL_RIM, fine=6, grime=10))


def hood_frame(side, tier):
    """The port hood on `side` of the edge tile (the side facing the block): a rounded cowling
    over the belt's block-side half, the block's height, with the belt's mouth at its far end."""
    c = Canvas(FRAME, FRAME)
    t0 = HOOD_PAD
    t1 = t0 + T
    inset = 6
    depth = 34
    W_ = FRAME
    if side in ("s", "n"):
        x0, x1 = t0 + inset, t1 - inset
        if side == "s":  # block to the south; the belt comes from the north into the mouth
            y0, y1 = t1 - depth, t1 + 1
            c.put(rect(W_, W_, x0 + 4, y0 - 4, x1 - 4, y0 + 3, 3) * 0.85, HOLE)
            top = rect(W_, W_, x0, y0, x1, y1, 3)
        else:  # block to the north; the mouth faces south, at the cowl's front end
            y0, y1 = t0 - 1, t0 + depth - FACE + 2
            top = rect(W_, W_, x0, y0 - 3, x1, y1, 3) * rect(W_, W_, x0, y0, x1, y1)
        c.put(top, paint_field(c, t0, t0, TIERS[tier]))
        cowl_shade(c, top, "x", x0, x1)
        # dark outline at the sides
        c.put(top * (rect(W_, W_, x1 - 1.2, y0, x1, y1)), SHADE)
        c.put(top * (rect(W_, W_, x0, y0, x0 + 1, y1)) * 0.6, np.array((190, 184, 172), float))
        # ribs across the cowl
        for k in (0.35, 0.7):
            yy = y0 + (y1 - y0) * k
            c.put(top * rect(W_, W_, x0, yy, x1, yy + 1.0) * 0.55, SHADE)
            c.put(top * rect(W_, W_, x0, yy + 1.0, x1, yy + 1.8) * 0.35, np.array((200, 194, 180), float))
        if side == "s":
            band = top * rect(W_, W_, x0, y0, x1, y0 + 5)
            tier_band(c, band, tier, t0, t0)
            c.put(top * rect(W_, W_, x0, y0, x1, y0 + 1) * 0.8, np.array((230, 220, 190), float))
            c.put(top * rect(W_, W_, x0, y0 + 5, x1, y0 + 6) * 0.8, SHADE)
            for bx in (x0 + 5, x1 - 5):
                rivet(c, bx, y0 + 2.5, 1.2)
        else:
            face(c, x0, x1, y1, tier, t0, True, True, slot=(x0 + 7, x1 - 7))
    else:
        y0, y1 = t0 + inset, t1 - inset - FACE + 4
        if side == "w":  # block to the west; the mouth faces east
            x0, x1 = t0 - 1, t0 + depth
            mx = x1 - 3
        else:
            x0, x1 = t1 - depth, t1 + 1
            mx = x0 - 4
        c.put(rect(W_, W_, mx, y0 + 3, mx + 7, y1 + FACE - 3, 2) * 0.85, HOLE)
        top = rect(W_, W_, x0, y0, x1, y1, 3)
        c.put(top, paint_field(c, t0, t0, TIERS[tier]))
        cowl_shade(c, top, "y", y0, y1)
        for k in (0.35, 0.7):
            xx = x0 + (x1 - x0) * k
            c.put(top * rect(W_, W_, xx, y0, xx + 1.0, y1) * 0.55, SHADE)
            c.put(top * rect(W_, W_, xx + 1.0, y0, xx + 1.8, y1) * 0.35, np.array((200, 194, 180), float))
        bx0 = x1 - 5 if side == "w" else x0
        band = top * rect(W_, W_, bx0, y0, bx0 + 5, y1)
        tier_band(c, band, tier, t0, t0)
        c.put(top * rect(W_, W_, x0, y0, x1, y0 + 1) * 0.8, np.array((210, 204, 190), float))
        face(c, x0, x1, y1, tier, t0, side == "e", side == "w")
    return c.image()


def mark(c, x, y, tier, d):
    """A tier-coloured chevron pointing `d` on a hood top."""
    col = np.array(TIERS[tier], float)
    ux, uy = {"n": (0, -1), "s": (0, 1), "e": (1, 0), "w": (-1, 0)}[d]
    nx, ny = -uy, ux
    pts = [(x - ux * 3 + nx * 6, y - uy * 3 + ny * 6), (x + ux * 3, y + uy * 3),
           (x - ux * 3 - nx * 6, y - uy * 3 - ny * 6), (x - ux * 0.2, y - uy * 0.2)]
    c.put(poly(c.w, c.h, [(px + 0.9, py + 0.9) for px, py in pts]) * 0.7, SHADE)
    c.put(poly(c.w, c.h, pts), col)


def hood_shadow(side):
    img = hood_frame(side, "basic")
    a = img.getchannel("A")
    sh = Image.new("L", img.size, 0)
    sh.paste(a, (SHADOW_DX - 3, SHADOW_DY))
    sh = sh.filter(ImageFilter.GaussianBlur(1.8)).point(lambda v: int(v * 1.0))
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.putalpha(sh)
    return out


# ---------------------------------------------------------------- main


def sheet(frames, per_line):
    rows = (len(frames) + per_line - 1) // per_line
    out = Image.new("RGBA", (FRAME * per_line, FRAME * rows), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        out.paste(f, ((i % per_line) * FRAME, (i // per_line) * FRAME))
    return out


def _job(args):
    global STYLE
    kind, a, b, STYLE = args
    if kind == "block":
        return block_frame(a, b)
    if kind == "hood":
        return hood_frame(a, b)
    if kind == "bshadow":
        return block_shadow(a)
    return hood_shadow(a)


def main():
    import sys
    global STYLE
    if len(sys.argv) > 1:
        STYLE = sys.argv[1]
    from multiprocessing import Pool
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(ICONS, exist_ok=True)
    ms = masks()
    assert len(ms) == 47, len(ms)
    order = ["n", "e", "s", "w", "n", "e"]
    jobs = [("bshadow", m, None) for m in ms] + [("hshadow", s, None) for s in "nesw"]
    for tier in TIERS:
        jobs += [("block", m, tier) for m in ms] + [("hood", s, tier) for s in "nesw"]
    with Pool() as pool:
        res = dict(zip(jobs, pool.map(_job, [j + (STYLE,) for j in jobs])))
    sheet([res[("bshadow", m, None)] for m in ms], 8).save(os.path.join(OUT, "balancer-shadow.png"), optimize=True)
    sheet([res[("hshadow", s, None)] for s in order], 6).save(os.path.join(OUT, "hood-shadow.png"), optimize=True)
    for tier in TIERS:
        frames = [res[("block", m, tier)] for m in ms]
        sheet(frames, 8).save(os.path.join(OUT, "balancer-%s.png" % tier), optimize=True)
        sheet([res[("hood", s, tier)] for s in order], 6).save(os.path.join(OUT, "hood-%s.png" % tier), optimize=True)
        # icon: a lone block with an input hood above and an output hood below, scaled to 64 px
        hs = res[("hood", "s", tier)]  # hood south of its tile: sits on top of the block
        hn = res[("hood", "n", tier)]  # hood north of its tile: sits under the block
        scene = Image.new("RGBA", (FRAME * 2, FRAME * 3), (0, 0, 0, 0))
        bx, by = FRAME // 2, FRAME
        scene.alpha_composite(hs, (bx + PAD_X - HOOD_PAD, by + PAD_Y - T - HOOD_PAD))
        scene.alpha_composite(frames[0], (bx, by))
        scene.alpha_composite(hn, (bx + PAD_X - HOOD_PAD, by + PAD_Y + T - HOOD_PAD))
        bbox = scene.getbbox()
        icon = scene.crop(bbox)
        canvas = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        k = 62 / max(icon.size)
        icon = icon.resize((round(icon.size[0] * k), round(icon.size[1] * k)), Image.LANCZOS)
        canvas.alpha_composite(icon, ((64 - icon.size[0]) // 2, (64 - icon.size[1]) // 2))
        canvas.save(os.path.join(ICONS, "balancer-%s.png" % tier), optimize=True)
    print("ok")


if __name__ == "__main__":
    main()
