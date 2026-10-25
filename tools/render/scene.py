"""Renders the balancer block, its animated machinery and the port hoods in Blender (Plan 3 Task 4).

Run headless from the repo root (raw renders go to the git-ignored tools/render/out/raw):
    E:\\Blender\\blender-5.2.3-windows-x64\\blender.exe -b --factory-startup --python tools/render/scene.py -- [out_dir] [--quick] [--calib]
then `python tools/render/pack.py` builds the game's sheets.

Camera: orthographic, 45 degrees down from the south. The scene is scaled by sqrt(2) along Y, so the
ground comes out square (1 tile = 192 render px) and a height h shows as 0.707 h above its footprint,
which gives the front (south) faces their height like vanilla entities. Key sun from the upper left
(shadows fall to the lower right), a soft fill and a grey world. Frames are 2 x 2 tiles, the block's
tile in the middle.

Renders:
  block-<tier>-<mask>.png   the static housing per connected neighbourhood (47 masks,
                            scripts/look.lua), modelled with its neighbours so the rounded outline
                            and inner corners are real geometry; pack.py cuts the neighbours away
  block-shadow.png          the shadow alone (shadow catcher), for a `draw_as_shadow` layer
  anim-<tier>-<f>.png       16 frames of the machinery in the top opening (crossing belt lanes
                            with moving treads, a turning diverter gear and rollers), the housing a
                            holdout, so it composites over every block variation
  hood-<tier>-<side>.png    the port housing an edge tile draws on its block-side half (the belt
  hood-shadow-<side>.png    runs under a low lip into the machine), sides n, e, s, w
  calib-<tier>.png          (--calib) a painted wall for the colour calibration (calibrate.py)

Tier paint colours come from tools/render/tiers.json (written by calibrate.py, which matches the
rendered paint to the vanilla splitter and underground belt sprites of each tier).
"""

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QUICK = "--quick" in argv
CALIB = "--calib" in argv
argv = [a for a in argv if not a.startswith("--")]
OUT = argv[0] if argv else os.path.join(HERE, "out", "raw")
os.makedirs(OUT, exist_ok=True)

FRAME_TILES = 2.0
RES = 384  # 192 render px per tile, 3 x the 64 px HR density
H = 0.55  # housing height (shows 0.39 tile of front face)
HOOD_H = 0.25  # port housing height
BEVEL = 0.04
PIT = 0.1  # depth of the machinery opening
WIN = 0.355  # half size of the opening
FRAMES = 16

with open(os.path.join(HERE, "tiers.json")) as f:
    TIERS = {k: tuple(v) for k, v in json.load(f).items()}  # linear base colours

N, E, S, W, NE, SE, SW, NW = 1, 2, 4, 8, 16, 32, 64, 128
CELL = {N: (0, 1), E: (1, 0), S: (0, -1), W: (-1, 0), NE: (1, 1), SE: (1, -1), SW: (-1, -1), NW: (-1, 1)}


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


# ---------------------------------------------------------------- scene


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 16 if QUICK else 64
    sc.cycles.use_denoising = False
    sc.cycles.max_bounces = 4
    sc.render.resolution_x = RES
    sc.render.resolution_y = RES
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    world = bpy.data.worlds.new("w")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.6, 0.6, 0.6, 1)
    bg.inputs["Strength"].default_value = 0.35

    root = bpy.data.objects.new("root", None)
    sc.collection.objects.link(root)
    root.scale = (1, math.sqrt(2), 1)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = FRAME_TILES
    cam_data.clip_start = 0.01
    cam_data.clip_end = 100
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    t = math.radians(45)
    cam.location = (0, -10 * math.sin(t), 10 * math.cos(t))
    cam.rotation_euler = (t, 0, 0)
    sc.camera = cam

    def sun(name, energy, angle, direction, shadow=True):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.use_shadow = shadow
        ob = bpy.data.objects.new(name, d)
        sc.collection.objects.link(ob)
        ob.rotation_euler = Vector(direction).normalized().to_track_quat("-Z", "Y").to_euler()

    sun("key", 3.0, 8, (1.0, -0.25, -1.4))
    sun("fill", 1.8, 40, (0.15, 1.0, -0.55), shadow=False)

    me = bpy.data.meshes.new("ground")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=6)
    bm.to_mesh(me)
    bm.free()
    ground = bpy.data.objects.new("ground", me)
    sc.collection.objects.link(ground)
    ground.parent = root
    ground.is_shadow_catcher = True
    # no grey bounce light from the ground onto the walls (it washed the paint out)
    ground.visible_diffuse = False
    ground.visible_glossy = False
    ground.visible_transmission = False
    return root, ground, world


# ---------------------------------------------------------------- materials


def periodic_noise(nt, scale, detail=4.0, roughness=0.6, w_offset=0.0):
    """4D noise of object position on a torus: periodic with the tile grid (seamless joins)."""
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    trig = []
    for axis in ("X", "Y"):
        m = nt.nodes.new("ShaderNodeMath")
        m.operation = "MULTIPLY"
        m.inputs[1].default_value = 2 * math.pi
        nt.links.new(sep.outputs[axis], m.inputs[0])
        c = nt.nodes.new("ShaderNodeMath")
        c.operation = "COSINE"
        s = nt.nodes.new("ShaderNodeMath")
        s.operation = "SINE"
        nt.links.new(m.outputs[0], c.inputs[0])
        nt.links.new(m.outputs[0], s.inputs[0])
        trig.append((c, s))
    comb = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(trig[0][0].outputs[0], comb.inputs[0])
    nt.links.new(trig[0][1].outputs[0], comb.inputs[1])
    nt.links.new(trig[1][0].outputs[0], comb.inputs[2])
    wsum = nt.nodes.new("ShaderNodeMath")
    wsum.operation = "ADD"
    wsum.inputs[1].default_value = w_offset
    nt.links.new(trig[1][1].outputs[0], wsum.inputs[0])
    zmul = nt.nodes.new("ShaderNodeMath")
    zmul.operation = "MULTIPLY_ADD"
    zmul.inputs[1].default_value = 3.0
    nt.links.new(sep.outputs["Z"], zmul.inputs[0])
    nt.links.new(wsum.outputs[0], zmul.inputs[2])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = detail
    noise.inputs["Roughness"].default_value = roughness
    nt.links.new(comb.outputs[0], noise.inputs["Vector"])
    nt.links.new(zmul.outputs[0], noise.inputs["W"])
    return noise.outputs["Fac"], sep


def mix(nt, fac, a, b):
    m = nt.nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    nt.links.new(fac, m.inputs["Factor"])
    # by identifier: the Mix node has a Float, Vector and Color socket named "A" (and "Result")
    ins = {i.identifier: i for i in m.inputs}
    for key, v in (("A_Color", a), ("B_Color", b)):
        if isinstance(v, tuple):
            ins[key].default_value = v + (1,)
        else:
            nt.links.new(v, ins[key])
    return {o.identifier: o for o in m.outputs}["Result_Color"]


def ramp(nt, fac, lo, hi):
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = lo
    mr.inputs["From Max"].default_value = hi
    mr.clamp = True
    nt.links.new(fac, mr.inputs["Value"])
    return mr.outputs["Result"]


def mul(nt, a, b):
    m = nt.nodes.new("ShaderNodeMath")
    m.operation = "MULTIPLY"
    m.use_clamp = True
    nt.links.new(a, m.inputs[0])
    if isinstance(b, float):
        m.inputs[1].default_value = b
    else:
        nt.links.new(b, m.inputs[1])
    return m.outputs[0]


BARE = (0.20, 0.19, 0.175)  # bare steel where paint chipped off
GRIME = (0.035, 0.028, 0.02)
DUST = (0.30, 0.27, 0.22)
OIL = (0.012, 0.010, 0.008)


def material(name, base, metallic=0.1, roughness=0.6, chips=0.0, grime=0.8, dust=0.25, oil=0.0, top=None,
             specular=0.5):
    """Weathered paint or metal: blotchy dirt, chipped paint on convex edges (bare steel), grime in
    recesses (ambient occlusion), dust on top faces, oil stains. With `top`, faces pointing up use
    that colour (steel top over painted walls)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Specular IOR Level"].default_value = specular
    big, sep = periodic_noise(nt, 3.0)
    fine, _ = periodic_noise(nt, 11.0, detail=3.0, w_offset=5.0)
    blot = ramp(nt, big, 0.4, 0.7)
    col = mix(nt, mul(nt, blot, 0.35), base, tuple(v * 0.55 for v in base))
    col = mix(nt, mul(nt, ramp(nt, fine, 0.5, 0.75), 0.25), col, tuple(v * 0.7 for v in base))
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    if top is not None:
        sepn = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sepn.inputs[0])
        up = ramp(nt, sepn.outputs["Z"], 0.55, 0.8)
        tcol = mix(nt, mul(nt, blot, 0.35), top, tuple(v * 0.6 for v in top))
        col = mix(nt, up, col, tcol)
    if chips:
        # convex edges: where a bevel-rounded normal leaves the true normal (pointiness is per
        # vertex and smears across the large flat faces of a low-poly box)
        bev = nt.nodes.new("ShaderNodeBevel")
        bev.samples = 8
        bev.inputs["Radius"].default_value = 0.07
        dot = nt.nodes.new("ShaderNodeVectorMath")
        dot.operation = "DOT_PRODUCT"
        nt.links.new(bev.outputs["Normal"], dot.inputs[0])
        nt.links.new(geo.outputs["Normal"], dot.inputs[1])
        edge = ramp(nt, {o.identifier: o for o in dot.outputs}["Value"], 0.985, 0.9)
        chipmask = ramp(nt, fine, 0.3, 0.5)
        col = mix(nt, mul(nt, mul(nt, edge, chipmask), chips), col, BARE)
    if grime:
        # dirt collects toward the foot of the walls
        foot = ramp(nt, sep.outputs["Z"], 0.16, 0.0)
        col = mix(nt, mul(nt, foot, 0.55 * grime), col, tuple(v * 0.3 + g for v, g in zip(base, GRIME)))
    if oil:
        stain, _ = periodic_noise(nt, 5.0, detail=2.0, w_offset=11.0)
        col = mix(nt, mul(nt, ramp(nt, stain, 0.62, 0.7), oil), col, OIL)
    if dust:
        sepn2 = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sepn2.inputs[0])
        upd = ramp(nt, sepn2.outputs["Z"], 0.6, 0.95)
        col = mix(nt, mul(nt, mul(nt, upd, ramp(nt, big, 0.45, 0.8)), dust), col, DUST)
    if grime:
        ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
        ao.inputs["Distance"].default_value = 0.06
        ao.samples = 8
        inv = nt.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        nt.links.new(ao.outputs["AO"], inv.inputs[1])
        col = mix(nt, mul(nt, inv.outputs[0], grime), col, tuple(v * 0.2 + g * 0.3 for v, g in zip(base, GRIME)))
    nt.links.new(col, bsdf.inputs["Base Color"])
    return mat


def tread_material(name, accent):
    """Rubber belt lane with moving treads: dark bands every 0.05 tile along the lane's local X and
    a tier-coloured chevron band every 0.2 tile; the Value node `offset` moves them (one frame =
    0.2 / FRAMES)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.75
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    off = nt.nodes.new("ShaderNodeValue")
    off.name = "offset"
    off.outputs[0].default_value = 0.0
    pos = nt.nodes.new("ShaderNodeMath")
    pos.operation = "SUBTRACT"
    nt.links.new(sep.outputs["X"], pos.inputs[0])
    nt.links.new(off.outputs[0], pos.inputs[1])
    # chevron: band depends on x - |y| so it points along +X
    ay = nt.nodes.new("ShaderNodeMath")
    ay.operation = "ABSOLUTE"
    nt.links.new(sep.outputs["Y"], ay.inputs[0])
    chev = nt.nodes.new("ShaderNodeMath")
    chev.operation = "ADD"
    nt.links.new(pos.outputs[0], chev.inputs[0])
    nt.links.new(ay.outputs[0], chev.inputs[1])
    results = []
    for src, period, lo, hi in ((pos, 0.05, 0.62, 1.0), (chev, 0.2, 0.78, 0.9)):
        m = nt.nodes.new("ShaderNodeMath")
        m.operation = "PINGPONG" if False else "FRACT"
        d = nt.nodes.new("ShaderNodeMath")
        d.operation = "DIVIDE"
        d.inputs[1].default_value = period
        nt.links.new(src.outputs[0], d.inputs[0])
        nt.links.new(d.outputs[0], m.inputs[0])
        results.append(ramp(nt, m.outputs[0], lo, hi))
    col = mix(nt, results[0], (0.075, 0.07, 0.065), (0.018, 0.016, 0.015))
    col = mix(nt, results[1], col, accent)
    nt.links.new(col, bsdf.inputs["Base Color"])
    return mat


def materials(tier):
    c = TIERS[tier]
    steel = (0.10, 0.095, 0.088)
    return {
        "body": material("body-" + tier, c, 0.0, 0.7, chips=0.9, oil=0.5, top=steel, dust=0.12, specular=0.04),
        "paint": material("paint-" + tier, c, 0.0, 0.7, chips=0.9, specular=0.04),
        "steel": material("steel-" + tier, steel, 0.6, 0.45, chips=0.0, oil=0.4),
        "light": material("light-" + tier, (0.26, 0.25, 0.235), 0.5, 0.55, dust=0.1),
        "dark": material("dark-" + tier, (0.02, 0.018, 0.016), 0.2, 0.7, dust=0.0, grime=0.0),
        "tread": tread_material("tread-" + tier, c),
        "accent": material("accent-" + tier, c, 0.0, 0.6, dust=0.1, specular=0.04),
    }


# ---------------------------------------------------------------- geometry


def obj(bm, name, mat, parent, smooth=False):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = smooth
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.parent = parent
    return ob


def bevel(ob, width=BEVEL, segments=3, angle=30):
    mod = ob.modifiers.new("bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(angle)
    return mod


def box(parent, mat, x0, y0, z0, x1, y1, z1, bev=0.0, name="box"):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    for v in bm.verts:
        v.co.x = x0 + (v.co.x + 0.5) * (x1 - x0)
        v.co.y = y0 + (v.co.y + 0.5) * (y1 - y0)
        v.co.z = z0 + (v.co.z + 0.5) * (z1 - z0)
    ob = obj(bm, name, mat, parent)
    if bev:
        bevel(ob, bev, 2)
    return ob


def cyl(parent, mat, r, length, segs=20, name="cyl"):
    """Cylinder along local Z, centred at the origin; place and rotate the result."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=length)
    return obj(bm, name, mat, parent, smooth=True)


def roller(parent, mat, x, y, z, length, r, axis="X", spin=0.0, name="roller"):
    """A roller along X or Y with flats (so its turning shows)."""
    ob = cyl(parent, mat, r, length, segs=10, name=name)
    ob.location = (x, y, z)
    if axis == "X":
        ob.rotation_euler = (spin, math.radians(90), 0)
        ob.rotation_mode = "YXZ"
        ob.rotation_euler = (spin, math.radians(90), 0)
    else:
        ob.rotation_mode = "XYZ"
        ob.rotation_euler = (math.radians(90), spin, 0)
    return ob


def gear(parent, mat, x, y, z, r, teeth, thick, angle, name="gear"):
    g = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(g)
    g.parent = parent
    g.location = (x, y, z)
    g.rotation_euler = (0, 0, angle)
    c = cyl(g, mat, r * 0.82, thick, segs=24, name=name + "-body")
    c.location = (0, 0, 0)
    for i in range(teeth):
        a = 2 * math.pi * i / teeth
        t = box(g, mat, -r * 0.1, -r * 0.13, -thick / 2, r * 0.1, r * 0.13, thick / 2, name=name + "-tooth")
        t.location = (math.cos(a) * r * 0.9, math.sin(a) * r * 0.9, 0)
        t.rotation_euler = (0, 0, a)
    hub = cyl(g, mat, r * 0.3, thick * 1.6, segs=12, name=name + "-hub")
    return g


def housing(parent, mat, cells, height, opening=None):
    """One connected housing over `cells`: top faces and outline walls with shared vertices (the
    bevel rounds the outline only, inner corners too). `opening` = half size of a square opening
    in cell (0, 0), with walls down to height - PIT and a floor."""
    bm = bmesh.new()
    vs = {}

    def v(x, y, z):
        key = (round(x * 1000), round(y * 1000), round(z * 1000))
        if key not in vs:
            vs[key] = bm.verts.new((x, y, z))
        return vs[key]

    def quad(a, b, c, d):
        bm.faces.new((v(*a), v(*b), v(*c), v(*d)))

    for cx, cy in cells:
        x0, x1, y0, y1 = cx - 0.5, cx + 0.5, cy - 0.5, cy + 0.5
        h = height
        if opening and (cx, cy) == (0, 0):
            o = opening
            outer = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
            inner = [(-o, -o), (o, -o), (o, o), (-o, o)]
            for i in range(4):
                a, b = outer[i], outer[(i + 1) % 4]
                c, d = inner[(i + 1) % 4], inner[i]
                quad((a[0], a[1], h), (b[0], b[1], h), (c[0], c[1], h), (d[0], d[1], h))
            for i in range(4):
                a, b = inner[i], inner[(i + 1) % 4]
                quad((a[0], a[1], h), (b[0], b[1], h), (b[0], b[1], h - PIT), (a[0], a[1], h - PIT))
            quad((-o, -o, h - PIT), (-o, o, h - PIT), (o, o, h - PIT), (o, -o, h - PIT))
        else:
            quad((x0, y0, h), (x1, y0, h), (x1, y1, h), (x0, y1, h))
        for (dx, dy), (a, b) in (((0, -1), ((x0, y0), (x1, y0))), ((1, 0), ((x1, y0), (x1, y1))),
                                 ((0, 1), ((x1, y1), (x0, y1))), ((-1, 0), ((x0, y1), (x0, y0)))):
            if (cx + dx, cy + dy) not in cells:
                quad((a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], h), (a[0], a[1], h))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    ob = obj(bm, "housing", mat, parent)
    bevel(ob, BEVEL, 4)
    return ob


def rim_bands(parent, mat, cells, height, width=0.09, raise_=0.035):
    """Raised painted bands on the top outline, corner squares at convex and inner corners."""
    def put(x0, y0, x1, y1):
        box(parent, mat, x0, y0, height - 0.01, x1, y1, height + raise_, bev=0.012, name="band")

    for cx, cy in cells:
        x0, x1, y0, y1 = cx - 0.5, cx + 0.5, cy - 0.5, cy + 0.5
        n = (cx, cy + 1) not in cells
        s = (cx, cy - 1) not in cells
        e = (cx + 1, cy) not in cells
        w = (cx - 1, cy) not in cells
        if s:
            put(x0 + (width if w else 0), y0, x1 - (width if e else 0), y0 + width)
        if n:
            put(x0 + (width if w else 0), y1 - width, x1 - (width if e else 0), y1)
        if w:
            put(x0, y0 + (width if s else 0), x0 + width, y1 - (width if n else 0))
        if e:
            put(x1 - width, y0 + (width if s else 0), x1, y1 - (width if n else 0))
        for sx, sy, a, b in ((-1, -1, w, s), (1, -1, e, s), (-1, 1, w, n), (1, 1, e, n)):
            if (a and b) or ((not a) and (not b) and (cx + sx, cy + sy) not in cells):
                qx = x0 if sx < 0 else x1 - width
                qy = y0 if sy < 0 else y1 - width
                put(qx, qy, qx + width, qy + width)


def block(root, m, mask):
    """The static block: housing with the opening, rim bands, opening frame, bolts, and on an open
    south side the front: a louvred vent with a roller behind it and a dark kick plate."""
    cells = {(0, 0)}
    for bit, cell in CELL.items():
        if mask & bit:
            cells.add(cell)
    housing(root, m["body"], cells, H, opening=WIN)
    rim_bands(root, m["paint"], cells, H)
    o = WIN
    fw = 0.035
    for (x0, y0, x1, y1) in ((-o - fw, -o - fw, o + fw, -o), (-o - fw, o, o + fw, o + fw),
                             (-o - fw, -o, -o, o), (o, -o, o + fw, o)):
        box(root, m["light"], x0, y0, H - 0.005, x1, y1, H + 0.02, bev=0.008, name="frame")
    for sx in (-1, 1):
        for sy in (-1, 1):
            b = cyl(root, m["light"], 0.025, 0.03, segs=10, name="bolt")
            b.location = (sx * (o + 0.065), sy * (o + 0.065), H + 0.01)
    if not mask & S:
        # front vent: a dark recess with louvres and a roller seen through them
        y = -0.5
        box(root, m["dark"], -0.3, y - 0.004, 0.12, 0.3, y + 0.03, 0.4, name="vent")
        for i in range(4):
            z = 0.16 + i * 0.065
            lv = box(root, m["steel"], -0.29, y - 0.02, z, 0.29, y + 0.01, z + 0.022, bev=0.006, name="louvre")
        box(root, m["steel"], -0.47, y - 0.012, 0.0, 0.47, y + 0.02, 0.07, bev=0.01, name="kick")
        for x in (-0.38, 0.38):
            b = cyl(root, m["light"], 0.022, 0.03, segs=10, name="fbolt")
            b.location = (x, y - 0.012, 0.27)
            b.rotation_euler = (math.radians(90), 0, 0)


def machinery(root, m, frame):
    """The working parts in the opening at animation frame `frame` of FRAMES: two belt lanes
    crossing (treads moving outward from the centre, toward the four corners), a diverter gear in
    the middle and four corner rollers, all looping."""
    t = frame / FRAMES
    z0 = H - PIT
    box(root, m["dark"], -WIN + 0.005, -WIN + 0.005, z0 - 0.01, WIN - 0.005, WIN - 0.005, z0 + 0.003, name="floor")
    lane_w = 0.17
    for ang in (45, 135):
        ln = box(root, m["tread"], -0.42, -lane_w / 2, z0, 0.42, lane_w / 2, z0 + 0.035, bev=0.008, name="lane")
        ln.rotation_euler = (0, 0, math.radians(ang))
    m["tread"].node_tree.nodes["offset"].outputs[0].default_value = 0.2 * t
    teeth = 10
    gear(root, m["light"], 0, 0, z0 + 0.075, 0.11, teeth, 0.035, 2 * math.pi * t / teeth, name="diverter")
    cap = cyl(root, m["accent"], 0.04, 0.02, segs=12, name="cap")
    cap.location = (0, 0, z0 + 0.11)
    for sx in (-1, 1):
        for sy in (-1, 1):
            g = gear(root, m["light"], sx * 0.24, sy * 0.24, z0 + 0.04, 0.06, 8,
                     0.025, -2 * math.pi * t / 8 * (1 if sx * sy > 0 else -1), name="small")


def hood(root, m, side):
    """The port housing on the half of an edge tile toward its block (`side` of the tile): belt
    side frames run along the belt into a low housing lip that reaches over the belt's last half
    tile; at the lip's open end the belt's end roller and a drive roller show in a dark mouth.
    Modelled with the block to the south ("s") and rotated."""
    g = bpy.data.objects.new("hood", None)
    bpy.context.scene.collection.objects.link(g)
    g.parent = root
    hw = 0.46  # half width
    y0, y1 = -0.5, -0.02  # the lip covers the half tile next to the block
    hh = HOOD_H
    # side cheeks (painted), the roof (steel top), a back plate against the block
    for sx in (-1, 1):
        x0, x1 = (sx * hw, sx * (hw - 0.11)) if sx < 0 else (sx * (hw - 0.11), sx * hw)
        box(g, m["paint"], min(x0, x1), y0, 0.0, max(x0, x1), y1, hh, bev=0.02, name="cheek")
    # the cover over the belt: transverse steel slats with dark gaps (a belt guard, the belt and
    # its items show darkly between them), on a steel cross beam at each end
    n_slats = 4
    span = (y1 - 0.06) - (y0 + 0.02)
    for k in range(n_slats):
        sy0 = y0 + 0.02 + k * span / n_slats
        box(g, m["steel"], -hw + 0.1, sy0, hh - 0.04, hw - 0.1, sy0 + span / n_slats * 0.62, hh - 0.005, bev=0.01,
            name="slat")
    box(g, m["dark"], -hw + 0.11, y0, 0.0, hw - 0.11, y1 - 0.02, hh - 0.06, name="inside")
    # lip at the open end: a steel bar with a painted stripe
    box(g, m["steel"], -hw, y1 - 0.05, hh - 0.11, hw, y1 + 0.015, hh + 0.005, bev=0.015, name="lip")
    box(g, m["accent"], -hw + 0.08, y1 - 0.035, hh + 0.004, hw - 0.08, y1 - 0.005, hh + 0.012, name="stripe")
    # rollers in the mouth: drive roller under the lip, belt end roller at belt level
    roller(g, m["light"], 0, y1 - 0.03, hh - 0.15, 2 * hw - 0.24, 0.035, axis="X", name="drive")
    roller(g, m["steel"], 0, y1 - 0.01, 0.045, 2 * hw - 0.24, 0.04, axis="X", name="endroll")
    # belt side frames continuing out of the housing (like the belt's own frame)
    for sx in (-1, 1):
        box(g, m["steel"], sx * (hw - 0.03) - 0.025, y1, 0.0, sx * (hw - 0.03) + 0.025, y1 + 0.16, 0.06, bev=0.01,
            name="rail")
    # bolts on the roof
    for x in (-0.3, 0.3):
        b = cyl(g, m["light"], 0.022, 0.03, segs=10, name="bolt")
        b.location = (x, (y0 + y1) / 2 - 0.05, hh + 0.005)
    g.rotation_euler = (0, 0, math.radians({"s": 0, "n": 180, "e": 90, "w": -90}[side]))
    return g


# ---------------------------------------------------------------- render


def clear(keep):
    for ob in list(bpy.context.scene.objects):
        if ob not in keep and ob.type in ("MESH", "EMPTY"):
            bpy.data.objects.remove(ob, do_unlink=True)


def render(path, ground, world, shadow=False, holdout=()):
    sc = bpy.context.scene
    for ob in sc.objects:
        if ob.type == "MESH" and ob is not ground:
            ob.visible_camera = not shadow
            ob.is_holdout = ob in holdout
    ground.hide_render = not shadow
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0 if shadow else 0.35
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    root, ground, world = reset()
    keep = (root, ground)
    tiers = list(TIERS)
    mats = {t: materials(t) for t in tiers}
    if CALIB:
        for t in tiers:
            clear(keep)
            mt = mats[t]["paint"]
            if os.environ.get("MB_CALIB_PLAIN"):
                mt = material("plain-" + t, TIERS[t], 0.0, 1.0, chips=0, grime=0, dust=0, specular=0.0)
            box(root, mt, -0.45, -0.5, 0.0, 0.45, 0.3, H, bev=0.03, name="wall")
            render(os.path.join(OUT, "calib-%s.png" % t), ground, world)
        print("RENDER DONE")
        return
    ms = masks()
    only = os.environ.get("MB_RENDER_ONLY")
    if only:
        ms = [ms[int(i)] for i in only.split(",")]
    clear(keep)
    housing(root, mats["basic"]["body"], {(0, 0)}, H)
    render(os.path.join(OUT, "block-shadow.png"), ground, world, shadow=True)
    for m in ms:
        for t in tiers:
            clear(keep)
            block(root, mats[t], m)
            render(os.path.join(OUT, "block-%s-%03d.png" % (t, m)), ground, world)
    nframes = 2 if os.environ.get("MB_RENDER_ONLY") else FRAMES
    for t in tiers:
        for f in range(nframes):
            clear(keep)
            block(root, mats[t], 0)
            static = [o for o in bpy.context.scene.objects if o.type == "MESH" and o is not ground]
            machinery(root, mats[t], f)
            render(os.path.join(OUT, "anim-%s-%02d.png" % (t, f)), ground, world, holdout=static)
    for side in "nesw":
        clear(keep)
        hood(root, mats["basic"], side)
        render(os.path.join(OUT, "hood-shadow-%s.png" % side), ground, world, shadow=True)
        for t in tiers:
            clear(keep)
            hood(root, mats[t], side)
            render(os.path.join(OUT, "hood-%s-%s.png" % (t, side)), ground, world)
    print("RENDER DONE")


main()
