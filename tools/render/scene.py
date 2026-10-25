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
HOOD_H = 0.3  # port roof height
BEVEL = 0.04
PIT = 0.1  # depth of the machinery opening
WIN = 0.41  # half size of the opening
FRAMES = 16

with open(os.path.join(HERE, "tiers.json")) as f:
    TIERS = {k: tuple(v) for k, v in json.load(f).items()}  # linear base colours
STEEL = TIERS.pop("steel", (0.10, 0.095, 0.088))  # the housing top and steel parts

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
    bg.inputs["Strength"].default_value = 0.18

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
    sun("fill", 0.9, 40, (0.15, 1.0, -0.55), shadow=False)

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


BARE = (0.022, 0.016, 0.011)  # chipped paint: dark, slightly rusty bare metal (vanilla keeps chips dark)
GRIME = (0.035, 0.028, 0.02)
DUST = (0.30, 0.27, 0.22)
OIL = (0.012, 0.010, 0.008)


def material(name, base, metallic=0.1, roughness=0.6, chips=0.0, grime=0.8, dust=0.25, oil=0.0, top=None,
             specular=0.5, streaks=0.0):
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
    grain, _ = periodic_noise(nt, 26.0, detail=6.0, roughness=0.75, w_offset=23.0)
    col = mix(nt, mul(nt, blot, 0.5), base, tuple(v * 0.5 for v in base))
    col = mix(nt, mul(nt, ramp(nt, fine, 0.5, 0.75), 0.25), col, tuple(v * 0.7 for v in base))
    col = mix(nt, mul(nt, ramp(nt, grain, 0.5, 0.68), 0.45), col, tuple(v * 0.55 for v in base))
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    if top is not None:
        sepn = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sepn.inputs[0])
        up = ramp(nt, sepn.outputs["Z"], 0.55, 0.8)
        tcol = mix(nt, mul(nt, blot, 0.85), top, tuple(v * 0.45 for v in top))
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
        edge = ramp(nt, {o.identifier: o for o in dot.outputs}["Value"], 0.995, 0.95)
        chipmask = ramp(nt, fine, 0.2, 0.36)
        # more wear on the walls than on the top
        sepc = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sepc.inputs[0])
        upc = ramp(nt, sepc.outputs["Z"], 0.5, 0.9)
        wallw = nt.nodes.new("ShaderNodeMath")
        wallw.operation = "MULTIPLY_ADD"
        wallw.inputs[1].default_value = -0.3
        wallw.inputs[2].default_value = 1.0
        nt.links.new(upc, wallw.inputs[0])
        chip = mul(nt, mul(nt, mul(nt, edge, chipmask), wallw.outputs[0]), chips)
        col = mix(nt, chip, col, BARE)
        # patches of chipped paint low on the walls and around the corners
        low = ramp(nt, sep.outputs["Z"], 0.22, 0.08)
        coarse, _ = periodic_noise(nt, 6.0, detail=3.0, roughness=0.7, w_offset=17.0)
        patch = mul(nt, mul(nt, ramp(nt, coarse, 0.5, 0.54), low), mul(nt, ramp(nt, sepc.outputs["Z"], 0.4, 0.1), chips))
        col = mix(nt, patch, col, BARE)
        # bare metal is glossier than paint
        rough = nt.nodes.new("ShaderNodeMapRange")
        rough.inputs["From Min"].default_value = 0.0
        rough.inputs["From Max"].default_value = 1.0
        rough.inputs["To Min"].default_value = roughness
        rough.inputs["To Max"].default_value = 0.28
        rough.clamp = True
        nt.links.new(chip, rough.inputs["Value"])
        nt.links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])
    if grime:
        # dirt collects toward the foot of the walls
        foot = ramp(nt, sep.outputs["Z"], 0.14, 0.0)
        col = mix(nt, mul(nt, foot, 0.55 * grime), col, tuple(v * 0.3 + g for v, g in zip(base, GRIME)))
    if streaks:
        # dirt streaks running down the walls: noise stretched along Z, walls only
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = (18.0, 18.0, 1.2)
        nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
        sn = nt.nodes.new("ShaderNodeTexNoise")
        sn.inputs["Scale"].default_value = 2.0
        sn.inputs["Detail"].default_value = 2.0
        nt.links.new(mp.outputs["Vector"], sn.inputs["Vector"])
        sepw = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sepw.inputs[0])
        wall = ramp(nt, sepw.outputs["Z"], 0.4, 0.1)
        st = mul(nt, mul(nt, ramp(nt, sn.outputs["Fac"], 0.55, 0.72), wall), streaks)
        col = mix(nt, st, col, tuple(v * 0.35 + g for v, g in zip(base, GRIME)))
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
        ao.inputs["Distance"].default_value = 0.12
        ao.samples = 8
        inv = nt.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        nt.links.new(ao.outputs["AO"], inv.inputs[1])
        col = mix(nt, mul(nt, inv.outputs[0], min(1.0, grime * 1.3)), col,
                  tuple(v * 0.12 + g * 0.2 for v, g in zip(base, GRIME)))
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
    col = mix(nt, results[0], (0.16, 0.165, 0.19), (0.05, 0.05, 0.06))
    col = mix(nt, results[1], col, accent)
    nt.links.new(col, bsdf.inputs["Base Color"])
    return mat


def materials(tier):
    c = TIERS[tier]
    steel = STEEL
    return {
        "body": material("body-" + tier, c, 0.0, 0.32, chips=1.0, oil=0.8, dust=0.05, specular=0.5,
                         streaks=0.7),
        "paint": material("paint-" + tier, c, 0.0, 0.32, chips=1.0, oil=0.3, specular=0.5, streaks=0.6),
        "steel": material("steel-" + tier, steel, 0.7, 0.3, chips=0.0, oil=0.4),
        "light": material("light-" + tier, tuple(v * 2.6 for v in steel), 0.7, 0.3, dust=0.1),
        "dark": material("dark-" + tier, (0.02, 0.018, 0.016), 0.2, 0.7, dust=0.0, grime=0.0),
        "tread": tread_material("tread-" + tier, c),
        "accent": material("accent-" + tier, c, 0.0, 0.32, dust=0.1, specular=0.5),
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


def rim_bands(parent, mat, cells, height, width=0.06, raise_=0.035):
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


def poly_prism(parent, mat, pts, z0, z1, name="prism"):
    """A prism with polygon footprint `pts` from z0 to z1."""
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, z0)) for x, y in pts]
    face = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext["geom"]:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = z1
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj(bm, name, mat, parent)


PLINTH = 0.1  # the low base under everything
DECK = 0.24  # the machinery deck
FRONT = 0.5  # the painted front housing
XC, XR = (0.0, 0.05), 0.2  # centre and half size of the raised X mechanism (same on every tile)


def plinth(root, mat, cells, height):
    """The base of tile (0, 0) only: its top and the walls on outline sides (none toward joined
    neighbours, so a group's base runs on without seams)."""
    bm = bmesh.new()
    x0, x1, y0, y1 = -0.5, 0.5, -0.5, 0.5
    h = height
    vs = {}

    def v(x, y, z):
        key = (round(x * 1000), round(y * 1000), round(z * 1000))
        if key not in vs:
            vs[key] = bm.verts.new((x, y, z))
        return vs[key]

    bm.faces.new((v(x0, y0, h), v(x1, y0, h), v(x1, y1, h), v(x0, y1, h)))
    for (dx, dy), (a, b) in (((0, -1), ((x0, y0), (x1, y0))), ((1, 0), ((x1, y0), (x1, y1))),
                             ((0, 1), ((x1, y1), (x0, y1))), ((-1, 0), ((x0, y1), (x0, y0)))):
        if (dx, dy) not in cells:
            bm.faces.new((v(a[0], a[1], 0), v(b[0], b[1], 0), v(b[0], b[1], h), v(a[0], a[1], h)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    ob = obj(bm, "plinth", mat, root)
    bevel(ob, 0.02, 2)
    return ob


def block(root, m, mask):
    """The static block in the vanilla splitter's language, for tile (0, 0) with neighbourhood
    `mask`: a dark base; a steel machinery deck (with rounded covers either side of the X); on an
    open south side the painted front housing that stands out over the belt with a V notch in its
    top edge (one chevron per tile, like vanilla's per-lane housings); on an open north side the
    long drive shaft with its rod, running on across joined east/west neighbours and capped only at
    the group's ends. The X mechanism itself is the animation (machinery())."""
    cells = {(0, 0)}
    for bit, cell in CELL.items():
        if mask & bit:
            cells.add(cell)
    n_open, s_open = not mask & N, not mask & S
    e_open, w_open = not mask & E, not mask & W
    xl = -0.47 if w_open else -0.5
    xr = 0.47 if e_open else 0.5
    plinth(root, m["dark"], cells, PLINTH)
    # machinery deck
    dy0 = -0.42 if s_open else -0.5
    dy1 = 0.3 if n_open else 0.5
    box(root, m["steel"], xl + 0.02, dy0, PLINTH - 0.01, xr - 0.02, dy1, DECK, bev=0.02, name="deck")
    # the X sits in a dark well in the deck
    box(root, m["dark"], XC[0] - XR - 0.05, XC[1] - XR - 0.05, DECK - 0.02, XC[0] + XR + 0.05, XC[1] + XR + 0.05,
        DECK + 0.002, name="well")
    # rounded covers either side of the X (vanilla's capsule covers)
    for sx in (-1, 1):
        cx = sx * 0.39
        if (sx > 0 and not e_open) or (sx < 0 and not w_open):
            cx = sx * 0.42
        cap = cyl(root, m["light"], 0.075, 0.42, segs=20, name="cover")
        cap.location = (cx, XC[1], DECK + 0.03)
        cap.rotation_euler = (math.radians(90), 0, 0)
        cap.scale = (1.0, 0.7, 1.0)
        for yy in (XC[1] - 0.2, XC[1] + 0.2):
            b = cyl(root, m["steel"], 0.085, 0.03, segs=16, name="cover-ring")
            b.location = (cx, yy, DECK + 0.03)
            b.rotation_euler = (math.radians(90), 0, 0)
            b.scale = (1.0, 0.75, 1.0)
    # rear drive shaft and rod (north side open)
    if n_open:
        y = 0.38
        cyl_x = cyl(root, m["light"], 0.055, xr - xl, segs=18, name="shaft")
        cyl_x.location = ((xl + xr) / 2, y, 0.36)
        cyl_x.rotation_euler = (0, math.radians(90), 0)
        rod = cyl(root, m["steel"], 0.026, xr - xl, segs=12, name="rod")
        rod.location = ((xl + xr) / 2, y + 0.07, 0.45)
        rod.rotation_euler = (0, math.radians(90), 0)
        for bx in (-0.25, 0.25):
            box(root, m["steel"], bx - 0.03, y - 0.06, DECK - 0.02, bx + 0.03, y + 0.1, 0.47, bev=0.01, name="bracket")
        for end, ex in ((w_open, xl), (e_open, xr)):
            if end:
                c = cyl(root, m["steel"], 0.085, 0.06, segs=18, name="shaft-cap")
                c.location = (ex + (0.03 if ex < 0 else -0.03), y, 0.36)
                c.rotation_euler = (0, math.radians(90), 0)
                k = cyl(root, m["accent"], 0.04, 0.07, segs=12, name="shaft-hub")
                k.location = (ex + (0.03 if ex < 0 else -0.03), y, 0.36)
                k.rotation_euler = (0, math.radians(90), 0)
    # painted front housing (south side open): V notch in its top edge
    if s_open:
        pts = [(xl, -0.5), (xr, -0.5), (xr, -0.3), (0.0, -0.4), (xl, -0.3)]
        hb = poly_prism(root, m["paint"], pts, PLINTH - 0.02, FRONT, name="front")
        bevel(hb, 0.025, 3)
        for bx, by in ((xl + 0.06, -0.36), (xr - 0.06, -0.36)):
            b = cyl(root, m["light"], 0.024, 0.03, segs=10, name="bolt")
            b.location = (bx, by, FRONT + 0.005)
        box(root, m["steel"], xl, -0.515, 0.0, xr, -0.49, 0.07, bev=0.01, name="kick")


def machinery(root, m, frame):
    """The raised X mechanism at animation frame `frame` of FRAMES: two belt lanes crossing (treads
    running out toward the corners), a diverter gear in the middle and a gear at each of the four
    ends, all looping."""
    t = frame / FRAMES
    z0 = DECK - 0.015
    cx, cy = XC
    m["tread"].node_tree.nodes["offset"].outputs[0].default_value = 0.2 * t
    lane_w = 0.1
    ln = XR * math.sqrt(2)
    for ang in (45, 135):
        o = box(root, m["tread"], -ln, -lane_w / 2, z0, ln, lane_w / 2, z0 + 0.03, bev=0.008, name="lane")
        o.location = (cx, cy, 0)
        o.rotation_euler = (0, 0, math.radians(ang))
    gear(root, m["light"], cx, cy, z0 + 0.07, 0.07, 10, 0.035, 2 * math.pi * t / 10, name="diverter")
    c = cyl(root, m["accent"], 0.03, 0.02, segs=12, name="cap")
    c.location = (cx, cy, z0 + 0.1)
    for sx in (-1, 1):
        for sy in (-1, 1):
            gear(root, m["light"], cx + sx * XR, cy + sy * XR, z0 + 0.045, 0.045, 8, 0.03,
                 -2 * math.pi * t / 8 * sx * sy, name="corner")


def group(parent, name, rot=0.0):
    g = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(g)
    g.parent = parent
    g.rotation_euler = (0, 0, rot)
    return g


def gloom_material(alpha=0.3):
    """Translucent black: the shade under a port's roof, over the belt drawn below it."""
    mat = bpy.data.materials.new("gloom")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["Specular IOR Level"].default_value = 0.0
    bsdf.inputs["Alpha"].default_value = alpha
    return mat


def hood(root, m, side):
    """The port on the half of an edge tile toward its block (`side` of the tile). The belt runs on
    visibly under a raised roof: the roof (steel top, painted edges, a tier stripe and a drive
    roller under its front edge) stands on two narrow side frames, the belt's own frame rails run
    out of it, and the belt under the roof is shaded darker toward the block, where the items go
    in. Modelled with the block to the south ("s") and rotated."""
    g = group(root, "hood", math.radians({"s": 0, "n": 180, "e": 90, "w": -90}[side]))
    hw = 0.47
    y0, y1 = -0.5, -0.04  # the roof reaches to the middle of the tile: items come out from under it
    # in front of the block (block to the north) the roof stays low, so the block's painted front
    # face shows above it, as the vanilla splitter's front stands over its belt
    hh = 0.13 if side == "n" else HOOD_H
    box(g, m["body"], -hw, y0, hh - 0.06, hw, y1, hh, bev=0.02, name="roof")
    box(g, m["paint"], -hw + 0.04, y1 - 0.05, hh - 0.005, hw - 0.04, y1 - 0.015, hh + 0.012, name="stripe")
    # dark bands across the painted roof, like the dark stripes on vanilla's underground belt hoods
    for k in range(3 if side != "n" else 2):
        by = y0 + 0.05 + k * 0.12
        box(g, m["dark"], -hw + 0.03, by, hh - 0.004, hw - 0.03, by + 0.05, hh + 0.006, name="band")
    for x in (-0.18, 0.18):
        box(g, m["steel"], x - 0.025, y0, hh - 0.01, x + 0.025, y1 - 0.05, hh + 0.02, bev=0.008, name="rib")
    roller(g, m["light"], 0, y1 - 0.02, hh - 0.09, 2 * hw - 0.14, 0.03, axis="X", name="drive")
    for sx in (-1, 1):
        x0, x1 = sorted((sx * hw, sx * (hw - 0.065)))
        box(g, m["paint"], x0, y0, 0.0, x1, y1, hh - 0.05, bev=0.012, name="cheek")
        hx = x0 - 0.002 if sx < 0 else x1 - 0.004
        box(g, m["dark"], hx, y0 + 0.06, 0.07, hx + 0.006, y1 - 0.05, 0.15, name="hole")
    for sx in (-1, 1):
        rx = sx * 0.44
        box(g, m["steel"], rx - 0.025, y1, 0.0, rx + 0.025, y1 + 0.3, 0.05, bev=0.008, name="rail")
        for by in (y1 + 0.1, y1 + 0.22):
            b = cyl(g, m["light"], 0.014, 0.02, segs=8, name="bolt")
            b.location = (rx, by, 0.055)
    gloom = gloom_material(0.3)
    # the belt darkens as it runs in under the lip, out to the middle of the tile where the items
    # pass into the link
    box(g, gloom, -0.4, y0, 0.004, 0.4, y1, 0.008, name="gloom")
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
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0 if shadow else 0.18
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
            block(root, mats[t], 0)
            render(os.path.join(OUT, "calib-%s.png" % t), ground, world)
        print("RENDER DONE")
        return
    ms = masks()
    only = os.environ.get("MB_RENDER_ONLY")
    if only:
        ms = [ms[int(i)] for i in only.split(",")]
    clear(keep)
    block(root, mats["basic"], 0)
    machinery(root, mats["basic"], 0)
    render(os.path.join(OUT, "block-shadow.png"), ground, world, shadow=True)
    for m in ms:
        for t in tiers:
            clear(keep)
            block(root, mats[t], m)
            render(os.path.join(OUT, "block-%s-%03d.png" % (t, m)), ground, world)
    nframes = 2 if os.environ.get("MB_RENDER_ONLY") else FRAMES
    for t in tiers:
        for suffix, smask in (("", 0), ("-s", S)):
            for f in range(nframes):
                clear(keep)
                block(root, mats[t], smask)
                static = [o for o in bpy.context.scene.objects if o.type == "MESH" and o is not ground]
                machinery(root, mats[t], f)
                render(os.path.join(OUT, "anim-%s%s-%02d.png" % (t, suffix, f)), ground, world, holdout=static)
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
