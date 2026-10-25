"""Renders the balancer block and port hood sprites in Blender (Plan 3 Task 4, round 3).

Run headless from the repo root:
    E:\\Blender\\blender-5.2.3-windows-x64\\blender.exe -b --factory-startup --python tools/render/scene.py -- [out_dir] [--quick]

Writes raw renders (RGBA PNG, 3x supersampled, 336 px per 1.75 tiles) to out_dir (default
tools/render/out/raw); tools/render/pack.py turns them into the game's sprite sheets.

Camera: orthographic, 45 degrees down from the south, like Factorio's entity renders. The scene is
scaled by sqrt(2) along Y, so the ground plane comes out square (1 tile = 192 render px) and a height
h shows as 0.707 h above its footprint. Key light from the upper left (north-west), soft world
ambient. A separate pass renders only the shadow on a shadow catcher (for `draw_as_shadow`).

Block: one render per connected neighbourhood (47 masks, scripts/look.lua) and tier. The housing of
the tile and of its neighbours in the mask is modelled as one bevelled slab, so the outline is
rounded and joined sides run flat to the tile border; pack.py cuts everything outside the tile.
Hood: the cowl an edge tile draws over its block-side half (frames N, E, S, W).
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QUICK = "--quick" in argv
argv = [a for a in argv if not a.startswith("--")]
OUT = argv[0] if argv else os.path.join(ROOT, "tools", "render", "out", "raw")
os.makedirs(OUT, exist_ok=True)

RES = 336  # render px for the 1.75-tile frame: 192 px per tile (3 x 64)
FRAME_TILES = 1.75
H = 0.25 * math.sqrt(2)  # housing height: shows 0.25 tile (48 render px) above its footprint
BEVEL = 0.045
KICK = 0.06  # dark steel band at the foot of the walls
STEEL_TOP = (0.085, 0.08, 0.072)  # linear base colour of the housing top (dark steel)

TIERS = {
    "basic": (0.93, 0.64, 0.05),
    "fast": (0.85, 0.10, 0.06),
    "express": (0.06, 0.55, 0.80),
    "turbo": (0.50, 0.72, 0.12),
}

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


# ---------------------------------------------------------------- scene setup


def srgb(c):
    return tuple(((v + 0.055) / 1.055) ** 2.4 if v > 0.04045 else v / 12.92 for v in c)


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
    bg.inputs["Strength"].default_value = 0.3

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
    d = 10
    cam.location = (0, -d * math.sin(t), d * math.cos(t))
    cam.rotation_euler = (t, 0, 0)
    sc.camera = cam

    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3.0
    sun_data.angle = math.radians(6)
    sun = bpy.data.objects.new("sun", sun_data)
    sc.collection.objects.link(sun)
    # light from the upper left: travelling toward the east, slightly south, and down
    direction = Vector((1.0, -0.15, -0.8)).normalized()
    sun.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()

    fill_data = bpy.data.lights.new("fill", "SUN")
    fill_data.energy = 1.1
    fill_data.angle = math.radians(30)
    fill_data.use_shadow = False
    fill = bpy.data.objects.new("fill", fill_data)
    sc.collection.objects.link(fill)
    fill.rotation_euler = Vector((-0.2, 1.0, -0.7)).normalized().to_track_quat("-Z", "Y").to_euler()

    plane_mesh = bpy.data.meshes.new("ground")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=6)
    bm.to_mesh(plane_mesh)
    bm.free()
    ground = bpy.data.objects.new("ground", plane_mesh)
    sc.collection.objects.link(ground)
    ground.parent = root
    ground.is_shadow_catcher = True
    return root, ground, world


# ---------------------------------------------------------------- materials


def periodic_noise(nt, scale, detail=4.0, roughness=0.6):
    """A 4D noise of object position mapped on a torus: periodic with the tile grid, so
    neighbouring tiles continue seamlessly. Returns the Fac output socket."""
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    outs = []
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
        outs.append((c, s))
    comb = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(outs[0][0].outputs[0], comb.inputs[0])
    nt.links.new(outs[0][1].outputs[0], comb.inputs[1])
    nt.links.new(outs[1][0].outputs[0], comb.inputs[2])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = detail
    noise.inputs["Roughness"].default_value = roughness
    nt.links.new(comb.outputs[0], noise.inputs["Vector"])
    nt.links.new(outs[1][1].outputs[0], noise.inputs["W"])
    return noise.outputs["Fac"], sep


def mix_color(nt, fac, a, b):
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(fac, mix.inputs["Factor"])
    if isinstance(a, tuple):
        mix.inputs["A"].default_value = a + (1,)
    else:
        nt.links.new(a, mix.inputs["A"])
    if isinstance(b, tuple):
        mix.inputs["B"].default_value = b + (1,)
    else:
        nt.links.new(b, mix.inputs["B"])
    return mix.outputs["Result"]


def ramp(nt, fac, lo, hi):
    """Remaps fac from lo..hi to 0..1 (clamped)."""
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = lo
    mr.inputs["From Max"].default_value = hi
    mr.clamp = True
    nt.links.new(fac, mr.inputs["Value"])
    return mr.outputs["Result"]


def material(name, base, metallic, roughness, grime=0.35, kick=False, wear=0.0, stripes=0.0, top=None):
    """Weathered material: base colour darkened by periodic grime, lighter worn convex edges
    (Cycles pointiness), and with `kick` a dark steel band at the foot of the walls."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    big, sep = periodic_noise(nt, 3.0)
    fine, _ = periodic_noise(nt, 9.0, detail=2.0)
    dirt = ramp(nt, big, 0.42, 0.68)
    speck = ramp(nt, fine, 0.45, 0.75)
    col = mix_color(nt, dirt, base, tuple(v * (1 - grime) for v in base))
    col = mix_color(nt, speck, col, tuple(v * (1 - grime * 0.6) for v in base))
    if wear > 0:
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        edge = ramp(nt, geo.outputs["Pointiness"], 0.52, 0.6)
        m = nt.nodes.new("ShaderNodeMath")
        m.operation = "MULTIPLY"
        m.inputs[1].default_value = wear
        nt.links.new(edge, m.inputs[0])
        col = mix_color(nt, m.outputs[0], col, (0.42, 0.40, 0.37))
    if stripes:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        wave = nt.nodes.new("ShaderNodeTexWave")
        wave.wave_type = "BANDS"
        wave.bands_direction = "X"
        wave.inputs["Scale"].default_value = stripes
        wave.inputs["Distortion"].default_value = 0.0
        nt.links.new(tc.outputs["Object"], wave.inputs["Vector"])
        band = ramp(nt, wave.outputs["Fac"], 0.55, 0.75)
        col = mix_color(nt, band, col, tuple(v * 0.45 for v in base))
    if top is not None:
        # surfaces facing up get the `top` colour (steel), the walls keep `base` (the tier paint)
        geo3 = nt.nodes.new("ShaderNodeNewGeometry")
        geo2 = nt.nodes.new("ShaderNodeNewGeometry")
        sepn = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo2.outputs["Normal"], sepn.inputs[0])
        up = ramp(nt, sepn.outputs["Z"], 0.55, 0.75)
        topcol = mix_color(nt, dirt, top, tuple(v * 0.7 for v in top))
        topcol = mix_color(nt, speck, topcol, tuple(v * 1.25 for v in top))
        col = mix_color(nt, up, col, topcol)
    if kick:
        low = nt.nodes.new("ShaderNodeMath")
        low.operation = "LESS_THAN"
        low.inputs[1].default_value = KICK
        nt.links.new(sep.outputs["Z"], low.inputs[0])
        col = mix_color(nt, low.outputs[0], col, (0.06, 0.055, 0.05))
    nt.links.new(col, bsdf.inputs["Base Color"])
    return mat


def materials():
    return {
        "paint": material("paint", srgb(TIERS["basic"]), 0.15, 0.55, grime=0.42, kick=True, wear=0.8),
        "body": None,
        "band": None,
        "steel": material("steel", srgb((0.36, 0.35, 0.33)), 0.65, 0.45, grime=0.45, kick=True, wear=0.6),
        "dark": material("dark", srgb((0.07, 0.065, 0.06)), 0.2, 0.7, grime=0.2),
        "rubber": material("rubber", srgb((0.30, 0.27, 0.25)), 0.0, 0.75, grime=0.25, stripes=2.2),
        "accent": material("accent", srgb(TIERS["basic"]), 0.1, 0.45, grime=0.15),
        "bolt": material("bolt", srgb((0.55, 0.53, 0.5)), 0.8, 0.35, grime=0.3),
    }


_TIER_MATS = {}


def set_tier(mats, tier):
    """Points every object using the current paint and accent materials to `tier`'s."""
    if tier not in _TIER_MATS:
        c = srgb(TIERS[tier])
        _TIER_MATS[tier] = {
            "paint": material("paint-" + tier, c, 0.05, 0.6, grime=0.35, kick=True, wear=0.5),
            "accent": material("accent-" + tier, c, 0.1, 0.45, grime=0.15),
            "band": material("band-" + tier, c, 0.05, 0.65, grime=0.3, wear=0.3),
            "body": material("body-" + tier, c, 0.35, 0.5, grime=0.42, kick=True, wear=0.8, top=STEEL_TOP),
        }
    for key in ("paint", "accent", "body", "band"):
        new = _TIER_MATS[tier][key]
        if mats[key] is not new:
            if mats[key] is not None:
                mats[key].user_remap(new)
            mats[key] = new


# ---------------------------------------------------------------- geometry helpers


def obj_from_bm(bm, name, mat, root, smooth=False):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = smooth
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.parent = root
    return ob


def bevel_mod(ob, width=BEVEL, segments=3, angle=30):
    mod = ob.modifiers.new("bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(angle)
    mod.harden_normals = False
    return mod


def box(root, mat, x0, y0, z0, x1, y1, z1, bevel=0.0, segments=2, name="box"):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    for v in bm.verts:
        v.co.x = x0 + (v.co.x + 0.5) * (x1 - x0)
        v.co.y = y0 + (v.co.y + 0.5) * (y1 - y0)
        v.co.z = z0 + (v.co.z + 0.5) * (z1 - z0)
    ob = obj_from_bm(bm, name, mat, root)
    if bevel:
        bevel_mod(ob, bevel, segments)
    return ob


def cylinder(root, mat, x, y, z0, z1, r, segs=16, axis="Z", name="cyl", bevel=0.0):
    """A cylinder of radius r. axis "Z": from z0 to z1 at (x, y). axis "X" or "Y": centred on
    (x, y, z0) and z1 - z0 long along that axis."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=z1 - z0)
    ob = obj_from_bm(bm, name, mat, root, smooth=True)
    if axis == "Z":
        ob.location = (x, y, (z0 + z1) / 2)
    else:
        ob.location = (x, y, z0)
        ob.rotation_euler = (0, math.radians(90), 0) if axis == "X" else (math.radians(90), 0, 0)
    if bevel:
        bevel_mod(ob, bevel, 2)
    return ob


def poly_prism(root, mat, pts, z0, z1, name="prism"):
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, z0)) for x, y in pts]
    face = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext["geom"]:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = z1
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, mat, root)


def rim_bands(root, mat, cells, height, width=0.1, raise_=0.03):
    """Painted raised bands along the outline edges of `cells` on top of the housing, with corner
    squares at convex and inner corners (no overlapping boxes)."""
    def put(x0, y0, x1, y1):
        box(root, mat, x0, y0, height - 0.01, x1, y1, height + raise_, bevel=0.012, name="band")

    for cx, cy in cells:
        x0, x1, y0, y1 = cx - 0.5, cx + 0.5, cy - 0.5, cy + 0.5
        n = (cx, cy + 1) not in cells
        s_ = (cx, cy - 1) not in cells
        e = (cx + 1, cy) not in cells
        w = (cx - 1, cy) not in cells
        if s_:
            put(x0 + (width if w else 0), y0, x1 - (width if e else 0), y0 + width)
        if n:
            put(x0 + (width if w else 0), y1 - width, x1 - (width if e else 0), y1)
        if w:
            put(x0, y0 + (width if s_ else 0), x0 + width, y1 - (width if n else 0))
        if e:
            put(x1 - width, y0 + (width if s_ else 0), x1, y1 - (width if n else 0))
        # corners: convex (both sides open) or inner (both sides joined, diagonal missing)
        for sx, sy, a_, b_ in ((-1, -1, w, s_), (1, -1, e, s_), (-1, 1, w, n), (1, 1, e, n)):
            convex = a_ and b_
            inner = (not a_) and (not b_) and (cx + sx, cy + sy) not in cells
            if convex or inner:
                qx = x0 if sx < 0 else x1 - width
                qy = y0 if sy < 0 else y1 - width
                put(qx, qy, qx + width, qy + width)


def slab(root, mat, cells, height):
    """One connected housing over `cells` ({(cx, cy)}): top quads and walls only on outline edges,
    vertices shared, so the bevel rounds the outline only (inner corners too)."""
    bm = bmesh.new()
    verts = {}

    def v(x, y, z):
        key = (round(x * 2), round(y * 2), round(z * 1000))
        if key not in verts:
            verts[key] = bm.verts.new((x, y, z))
        return verts[key]

    for cx, cy in cells:
        x0, x1, y0, y1 = cx - 0.5, cx + 0.5, cy - 0.5, cy + 0.5
        bm.faces.new((v(x0, y0, height), v(x1, y0, height), v(x1, y1, height), v(x0, y1, height)))
        for (dx, dy), (a, b) in (((0, -1), ((x0, y0), (x1, y0))), ((1, 0), ((x1, y0), (x1, y1))),
                                 ((0, 1), ((x1, y1), (x0, y1))), ((-1, 0), ((x0, y1), (x0, y0)))):
            if (cx + dx, cy + dy) not in cells:
                bm.faces.new((v(a[0], a[1], 0), v(b[0], b[1], 0), v(b[0], b[1], height), v(a[0], a[1], height)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    ob = obj_from_bm(bm, "slab", mat, root)
    bevel_mod(ob, BEVEL, 4)
    return ob


# ---------------------------------------------------------------- the block


def block(root, mats, mask):
    cells = {(0, 0)}
    for bit, cell in CELL.items():
        if mask & bit:
            cells.add(cell)
    slab(root, mats["body"], cells, H)
    rim_bands(root, mats["band"], cells, H)
    top = H
    # the machinery window: a recessed dark bay with a steel frame, two belt lanes crossing in an
    # X around a diverter hub (splitting and merging), bolts at the corners
    b = 0.29  # half size of the window
    fr = 0.05  # frame width
    box(root, mats["steel"], -b - fr, -b - fr, top - 0.01, b + fr, b + fr, top + 0.025, bevel=0.012, name="frame")
    box(root, mats["dark"], -b, -b, top - 0.06, b, b, top + 0.026, name="bay")
    lane_w = 0.15
    for ang in (45, -45):
        ln = box(root, mats["rubber"], -0.36, -lane_w / 2, top + 0.0, 0.36, lane_w / 2, top + 0.03, bevel=0.01, name="lane")
        ln.rotation_euler = (0, 0, math.radians(ang))
        # chevrons along the lane, pointing outward from the hub (items leave toward the corners)
        for sgn in (1, -1):
            r0 = 0.2 * sgn
            tri = poly_prism(root, mats["accent"], [(r0 + 0.045 * sgn, 0), (r0 - 0.03 * sgn, 0.05), (r0 - 0.03 * sgn, -0.05)],
                             top + 0.03, top + 0.036, name="chev")
            tri.rotation_euler = (0, 0, math.radians(ang))
    cylinder(root, mats["steel"], 0, 0, top, top + 0.06, 0.085, segs=24, bevel=0.01, name="hub")
    cylinder(root, mats["accent"], 0, 0, top + 0.06, top + 0.07, 0.045, segs=20, name="cap")
    for sx in (-1, 1):
        for sy in (-1, 1):
            cylinder(root, mats["bolt"], sx * (b + fr + 0.045), sy * (b + fr + 0.045), top, top + 0.02, 0.028, segs=12,
                     name="bolt")
    # the front: two bolts on the south wall when it is an outline side
    if not mask & S:
        for x in (-0.3, 0.3):
            cylinder(root, mats["bolt"], x, -0.5 - 0.005, H * 0.55, H * 0.55 + 0.02, 0.026, segs=12, axis="Y",
                     name="fbolt")


# ---------------------------------------------------------------- the port hood


def hood(root, mats, side):
    """Cowl over the half of the edge tile toward the block, which lies on `side` of the tile.
    Modelled for side "s" (block to the south, belt coming from the north) and rotated."""
    group = bpy.data.objects.new("hood", None)
    bpy.context.scene.collection.objects.link(group)
    group.parent = root
    half = 0.38
    y0, y1 = -0.5, -0.03
    # arched cowl: box with strongly rounded top long edges
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    for v in bm.verts:
        v.co.x = v.co.x * 2 * half
        v.co.y = y0 + (v.co.y + 0.5) * (y1 - y0)
        v.co.z = (v.co.z + 0.5) * H
    edges = [e for e in bm.edges if all(v.co.z > H - 1e-4 for v in e.verts)
             and abs(e.verts[0].co.y - e.verts[1].co.y) > 0.1]
    bmesh.ops.bevel(bm, geom=edges, offset=0.15, segments=6, affect="EDGES", profile=0.5)
    ob = obj_from_bm(bm, "cowl", mats["paint"], group, smooth=False)
    bevel_mod(ob, 0.02, 2, angle=25)
    # steel ribs across the cowl
    for yy in (-0.42, -0.2):
        r = box(group, mats["steel"], -half - 0.012, yy - 0.025, 0.0, half + 0.012, yy + 0.025, H + 0.012, bevel=0.012,
                name="rib")
        r.modifiers.clear()
        bevel_mod(r, 0.06, 4, angle=25)
    # the mouth at the open end: a dark opening with a roller across its top and hanging flaps
    box(group, mats["dark"], -half + 0.06, y1 - 0.004, 0.0, half - 0.06, y1 + 0.01, H - 0.07, name="mouth")
    cylinder(group, mats["bolt"], 0, y1 + 0.02, H - 0.06, H - 0.06 + 2 * half - 0.1, 0.035, segs=16, axis="X",
             name="roller")
    for i in range(5):
        x = -half + 0.09 + i * (2 * half - 0.18) / 4.0
        box(group, mats["rubber"], x - 0.05, y1 + 0.005, 0.03, x + 0.05, y1 + 0.02, H - 0.1, name="flap")
    rot = {"s": 0, "n": 180, "e": 90, "w": -90}[side]
    group.rotation_euler = (0, 0, math.radians(rot))
    return group


# ---------------------------------------------------------------- render


def render(path, shadow_pass, ground, world, mats):
    sc = bpy.context.scene
    for ob in sc.objects:
        if ob.type == "MESH" and ob is not ground:
            ob.visible_camera = not shadow_pass
            ob.visible_shadow = True
    ground.hide_render = not shadow_pass
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0 if shadow_pass else 0.3
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def clear(root, ground):
    for ob in list(bpy.context.scene.objects):
        if ob not in (root, ground) and ob.type in ("MESH", "EMPTY"):
            bpy.data.objects.remove(ob, do_unlink=True)


def main():
    root, ground, world = reset()
    mats = materials()
    set_tier(mats, "basic")
    ms = masks()
    tiers = list(TIERS)
    only = os.environ.get("MB_RENDER_ONLY")  # e.g. "0,5" masks for quick looks
    if only:
        ms = [ms[int(i)] for i in only.split(",")]
    # block shadow: the same for every mask (shadows do not stack in the game), from a lone block
    clear(root, ground)
    slab(root, mats["paint"], {(0, 0)}, H)
    render(os.path.join(OUT, "block-shadow.png"), True, ground, world, mats)
    for i, m in enumerate(ms):
        clear(root, ground)
        block(root, mats, m)
        for tier in tiers:
            set_tier(mats, tier)
            render(os.path.join(OUT, "block-%s-%03d.png" % (tier, m)), False, ground, world, mats)
    for side in "nesw":
        clear(root, ground)
        hood(root, mats, side)
        render(os.path.join(OUT, "hood-shadow-%s.png" % side), True, ground, world, mats)
        for tier in tiers:
            set_tier(mats, tier)
            render(os.path.join(OUT, "hood-%s-%s.png" % (tier, side)), False, ground, world, mats)
    print("RENDER DONE")


main()
