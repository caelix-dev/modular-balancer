"""Renders the balancer block, its animated machinery and the port hoods in Blender (Plan 3 Task 4).

Run headless from the repo root (raw renders go to the git-ignored tools/render/out/raw):
    E:\\Blender\\blender-5.2.3-windows-x64\\blender.exe -b --factory-startup --python tools/render/scene.py -- [out_dir] [--quick] [--calib]
then `python tools/render/pack.py` builds the game's sheets.

Camera: orthographic, 45 degrees down from the south. The scene is scaled by sqrt(2) along Y, so the
ground comes out square (1 tile = 192 render px) and a height h shows as 0.707 h above its
footprint. Key sun
from the upper left (shadows fall to the lower right), a strong fill from the front (vanilla's
front faces are well lit) and a sky bright overhead. Frames are 2 x 2 tiles, the block's tile in
the middle.

Renders:
  block-<tier>-<mask>.png   the static housing per connected neighbourhood (47 masks,
                            scripts/look.lua), modelled with its neighbours so the rounded outline
                            and inner corners are real geometry; pack.py cuts the neighbours away
  block-shadow.png          the shadow alone (shadow catcher), for a `draw_as_shadow` layer
  anim-<tier>-<f>.png       16 frames of the machinery in the top opening (crossing belt lanes
                            with moving treads, a turning diverter gear and rollers), the housing a
                            holdout, so it composites over every block variation
  hood-<tier>-<side>-<flow>.png  the port housing an edge tile draws on its block-side half (the belt
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
H = 0.51  # housing height (shows 0.36 tile of front face)
HOOD_H = 0.3  # port roof height
BEVEL = 0.04
PIT = 0.1  # depth of the machinery opening
WIN = 0.355  # half size of the opening
FRAMES = 16
WORLD = 0.6  # sky strength
SQ2 = math.sqrt(2)

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
    # a sky that is bright overhead and dark toward the horizon and below, so metal and gloss show
    # bright tops and dark sides like vanilla's instead of a flat grey
    wn = world.node_tree
    tc = wn.nodes.new("ShaderNodeTexCoord")
    sepw = wn.nodes.new("ShaderNodeSeparateXYZ")
    wn.links.new(tc.outputs["Generated"], sepw.inputs[0])
    sky = wn.nodes.new("ShaderNodeValToRGB")
    sky.color_ramp.elements[0].position = 0.0
    sky.color_ramp.elements[0].color = (0.04, 0.04, 0.045, 1)
    sky.color_ramp.elements[1].position = 1.0
    sky.color_ramp.elements[1].color = (1.0, 0.98, 0.95, 1)
    sky.color_ramp.elements.new(0.35).color = (0.18, 0.18, 0.2, 1)
    wn.links.new(sepw.outputs["Z"], sky.inputs["Fac"])
    wn.links.new(sky.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = WORLD

    root = bpy.data.objects.new("root", None)
    sc.collection.objects.link(root)
    root.scale = (1, SQ2, 1)

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

    sun("key", 4.0, 8, (1.0, -0.25, -1.4))
    # vanilla lights the south (front) faces well: a strong fill from the front, no shadows
    sun("fill", 2.2, 40, (0.15, 1.0, -0.55), shadow=False)

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


BARE = (0.035, 0.024, 0.017)  # chipped paint: dark, slightly rusty bare metal (vanilla keeps chips dark)
RUST = (0.16, 0.05, 0.02)
GRIME = (0.035, 0.028, 0.02)
DUST = (0.30, 0.27, 0.22)
OIL = (0.012, 0.010, 0.008)


def noise3(nt, scale, detail=3.0, roughness=0.6, distortion=0.0):
    """Plain 3D noise of object position (fine detail that need not tile seamlessly)."""
    tc = nt.nodes.new("ShaderNodeTexCoord")
    n = nt.nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = scale
    n.inputs["Detail"].default_value = detail
    n.inputs["Roughness"].default_value = roughness
    n.inputs["Distortion"].default_value = distortion
    nt.links.new(tc.outputs["Object"], n.inputs["Vector"])
    return n.outputs["Fac"]


def material(name, base, metallic=0.1, roughness=0.6, chips=0.0, grime=0.8, dust=0.25, oil=0.0, top=None,
             specular=0.5, streaks=0.0, speckle=0.0, rust=0.0, coat=0.0, top_rust=0.0, grad=0.0):
    """Weathered paint or metal like vanilla's: blotchy dirt and a fine grunge speckle all over,
    dark chipped paint on convex edges and low on the walls, dirt streaks down the walls, grime in
    recesses (ambient occlusion), dust on top faces, oil stains, red rust spots on metal, and a
    clear coat on paint so its edges and faces catch the key light. With `top`, faces pointing up
    use that colour (steel top over painted walls)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Specular IOR Level"].default_value = specular
    if coat:
        # glossy paint reflects with a tint of its own colour (an untinted sheen washed the
        # saturated tiers out toward white)
        bsdf.inputs["Specular Tint"].default_value = tuple(0.5 + 0.5 * v for v in base) + (1,)
    if coat:
        bsdf.inputs["Coat Weight"].default_value = coat
        bsdf.inputs["Coat Roughness"].default_value = 0.15
    big, sep = periodic_noise(nt, 3.0)
    fine, _ = periodic_noise(nt, 11.0, detail=3.0, w_offset=5.0)
    blot = ramp(nt, big, 0.4, 0.7)
    col = mix(nt, mul(nt, blot, 0.35), base, tuple(v * 0.55 for v in base))
    col = mix(nt, mul(nt, ramp(nt, fine, 0.5, 0.75), 0.25), col, tuple(v * 0.7 for v in base))
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sepn = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Normal"], sepn.inputs[0])
    nz = sepn.outputs["Z"]
    if speckle:
        # vanilla's grunge: faded lighter patches, dark rust-brown smudges and dense small spots,
        # coarse enough to read at the game's 64 px per tile
        lighter = tuple(v * 1.3 for v in base)
        lp = noise3(nt, 4.0, detail=3.0, roughness=0.6, distortion=0.4)
        col = mix(nt, mul(nt, ramp(nt, lp, 0.5, 0.7), speckle * 0.6), col, lighter)
        rusty = tuple(v * 0.3 + r * 0.6 for v, r in zip(base, RUST))
        sp = noise3(nt, 20.0, detail=6.0, roughness=0.75)
        col = mix(nt, mul(nt, ramp(nt, sp, 0.46, 0.6), speckle), col, rusty)
        sm = noise3(nt, 7.0, detail=5.0, roughness=0.7, distortion=0.6)
        col = mix(nt, mul(nt, ramp(nt, sm, 0.45, 0.6), speckle), col, tuple(v * 0.22 + r * 0.35 for v, r in zip(base, RUST)))
        dots = noise3(nt, 45.0, detail=3.0, roughness=0.6)
        col = mix(nt, mul(nt, ramp(nt, dots, 0.6, 0.68), speckle), col, tuple(v * 0.25 + r * 0.4 for v, r in zip(base, RUST)))
    if rust:
        # red-brown rust spots and streaks on bare metal
        rs = noise3(nt, 9.0, detail=5.0, roughness=0.7, distortion=0.8)
        rmask = mul(nt, ramp(nt, rs, 0.6, 0.7), rust)
        col = mix(nt, rmask, col, RUST)
        rs2 = noise3(nt, 24.0, detail=4.0, roughness=0.7)
        col = mix(nt, mul(nt, ramp(nt, rs2, 0.55, 0.68), rust * 0.8), col, tuple(r * 0.6 for r in RUST))
    if top is not None:
        up = ramp(nt, nz, 0.55, 0.8)
        tcol = mix(nt, mul(nt, blot, 0.35), top, tuple(v * 0.6 for v in top))
        if top_rust:
            rs = noise3(nt, 9.0, detail=5.0, roughness=0.7, distortion=0.8)
            tcol = mix(nt, mul(nt, ramp(nt, rs, 0.6, 0.7), top_rust), tcol, RUST)
            rs2 = noise3(nt, 24.0, detail=4.0, roughness=0.7)
            tcol = mix(nt, mul(nt, ramp(nt, rs2, 0.52, 0.66), top_rust), tcol, tuple(v * 0.4 for v in top))
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
        cn = noise3(nt, 18.0, detail=5.0, roughness=0.7)
        chipmask = ramp(nt, cn, 0.42, 0.55)
        chip = mul(nt, mul(nt, edge, chipmask), chips)
        # small chips and scratches anywhere on the paint, more low on the walls
        low = ramp(nt, sep.outputs["Z"], 0.3, 0.02)
        wall = ramp(nt, nz, 0.5, 0.15)
        cn2 = noise3(nt, 14.0, detail=6.0, roughness=0.75, distortion=0.4)
        lowf = nt.nodes.new("ShaderNodeMath")
        lowf.operation = "MULTIPLY_ADD"
        lowf.inputs[1].default_value = 0.7
        lowf.inputs[2].default_value = 0.3
        nt.links.new(low, lowf.inputs[0])
        patch = mul(nt, mul(nt, ramp(nt, cn2, 0.64, 0.7), mul(nt, lowf.outputs[0], wall)), chips)
        amt = nt.nodes.new("ShaderNodeMath")
        amt.operation = "MAXIMUM"
        nt.links.new(chip, amt.inputs[0])
        nt.links.new(patch, amt.inputs[1])
        col = mix(nt, amt.outputs[0], col, BARE)
        # bare metal is glossier than paint
        rough = nt.nodes.new("ShaderNodeMapRange")
        rough.inputs["To Min"].default_value = roughness
        rough.inputs["To Max"].default_value = 0.3
        rough.clamp = True
        nt.links.new(amt.outputs[0], rough.inputs["Value"])
        nt.links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])
        if coat:
            # no clear coat where the paint is gone
            cw = nt.nodes.new("ShaderNodeMapRange")
            cw.inputs["To Min"].default_value = coat
            cw.inputs["To Max"].default_value = 0.0
            cw.clamp = True
            nt.links.new(amt.outputs[0], cw.inputs["Value"])
            nt.links.new(cw.outputs["Result"], bsdf.inputs["Coat Weight"])
    if grime:
        # dirt collects toward the foot of the walls
        foot = ramp(nt, sep.outputs["Z"], 0.3, 0.0)
        col = mix(nt, mul(nt, foot, 0.6 * grime), col, tuple(v * 0.3 + r * 0.3 + g for v, r, g in zip(base, RUST, GRIME)))
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
        wall2 = ramp(nt, nz, 0.4, 0.1)
        st = mul(nt, mul(nt, ramp(nt, sn.outputs["Fac"], 0.55, 0.72), wall2), streaks)
        col = mix(nt, st, col, tuple(v * 0.4 + g for v, g in zip(base, GRIME)))
    if oil:
        stain, _ = periodic_noise(nt, 5.0, detail=2.0, w_offset=11.0)
        col = mix(nt, mul(nt, ramp(nt, stain, 0.62, 0.7), oil), col, OIL)
    if dust:
        upd = ramp(nt, nz, 0.6, 0.95)
        col = mix(nt, mul(nt, mul(nt, upd, ramp(nt, big, 0.45, 0.8)), dust), col, DUST)
    if grad:
        gr = nt.nodes.new("ShaderNodeValToRGB")
        gr.color_ramp.elements[0].position = 0.0
        gr.color_ramp.elements[0].color = (0.55, 0.55, 0.55, 1)
        gr.color_ramp.elements[1].position = 1.0
        gr.color_ramp.elements[1].color = (1.35, 1.35, 1.35, 1)
        zr = ramp(nt, sep.outputs["Z"], 0.0, grad)
        nt.links.new(zr, gr.inputs["Fac"])
        mm = nt.nodes.new("ShaderNodeMix")
        mm.data_type = "RGBA"
        mm.blend_type = "MULTIPLY"
        ins = {i.identifier: i for i in mm.inputs}
        ins["Factor_Float"].default_value = 1.0
        nt.links.new(col, ins["A_Color"])
        nt.links.new(gr.outputs["Color"], ins["B_Color"])
        col = {o.identifier: o for o in mm.outputs}["Result_Color"]
    if grime:
        ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
        ao.inputs["Distance"].default_value = 0.1
        ao.samples = 8
        inv = nt.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        nt.links.new(ao.outputs["AO"], inv.inputs[1])
        col = mix(nt, mul(nt, inv.outputs[0], min(1.0, grime * 1.2)), col,
                  tuple(v * 0.15 + g * 0.25 for v, g in zip(base, GRIME)))
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
    # vanilla's steel: a cool blue-grey, glossy, with red-brown rust spots
    steel = (0.075, 0.08, 0.105)
    light = (0.17, 0.18, 0.22)
    paint = dict(chips=1.0, specular=1.0, coat=0.5, speckle=0.9, streaks=0.8, dust=0.0)
    return {
        "body": material("body-" + tier, c, 0.0, 0.38, oil=0.4, top=steel, top_rust=0.55, grad=0.55, **paint),
        "paint": material("paint-" + tier, c, 0.0, 0.38, oil=0.2, grad=0.3, **paint),
        "steel": material("steel-" + tier, steel, 0.55, 0.32, oil=0.4, rust=0.8, speckle=0.5),
        "light": material("light-" + tier, light, 0.55, 0.3, dust=0.05, rust=0.6, speckle=0.4),
        "dark": material("dark-" + tier, (0.02, 0.018, 0.016), 0.2, 0.7, dust=0.0, grime=0.0),
        "rubber": material("rubber-" + tier, (0.03, 0.028, 0.026), 0.0, 0.55, dust=0.15, grime=0.4, speckle=0.3),
        "tread": tread_material("tread-" + tier, c),
        "accent": material("accent-" + tier, c, 0.0, 0.38, dust=0.05, specular=0.5, coat=0.5, speckle=0.5),
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
            o, oy = opening, opening
            outer = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
            inner = [(-o, -oy), (o, -oy), (o, oy), (-o, oy)]
            for i in range(4):
                a, b = outer[i], outer[(i + 1) % 4]
                c, d = inner[(i + 1) % 4], inner[i]
                quad((a[0], a[1], h), (b[0], b[1], h), (c[0], c[1], h), (d[0], d[1], h))
            for i in range(4):
                a, b = inner[i], inner[(i + 1) % 4]
                quad((a[0], a[1], h), (b[0], b[1], h), (b[0], b[1], h - PIT), (a[0], a[1], h - PIT))
            quad((-o, -oy, h - PIT), (-o, oy, h - PIT), (o, oy, h - PIT), (o, -oy, h - PIT))
        else:
            quad((x0, y0, h), (x1, y0, h), (x1, y1, h), (x0, y1, h))
        for (dx, dy), (a, b) in (((0, -1), ((x0, y0), (x1, y0))), ((1, 0), ((x1, y0), (x1, y1))),
                                 ((0, 1), ((x1, y1), (x0, y1))), ((-1, 0), ((x0, y1), (x0, y0)))):
            if (cx + dx, cy + dy) not in cells:
                quad((a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], h), (a[0], a[1], h))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    ob = obj(bm, "housing", mat, parent)
    bevel(ob, 0.07, 5)  # a well rounded edge catches a bright highlight, like vanilla's housings
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
        # (all of it lower than a port's collar, so a port attached here covers it completely)
        y = -0.5
        box(root, m["dark"], -0.3, y - 0.004, 0.1, 0.3, y + 0.03, 0.33, name="vent")
        for i in range(4):
            z = 0.13 + i * 0.05
            lv = box(root, m["steel"], -0.29, y - 0.02, z, 0.29, y + 0.01, z + 0.02, bev=0.006, name="louvre")
        box(root, m["steel"], -0.42, y - 0.012, 0.0, 0.42, y + 0.02, 0.07, bev=0.01, name="kick")
        for x in (-0.37, 0.37):
            b = cyl(root, m["light"], 0.022, 0.03, segs=10, name="fbolt")
            b.location = (x, y - 0.012, 0.22)
            b.rotation_euler = (math.radians(90), 0, 0)


def machinery(root, m, frame):
    """The working parts in the opening at animation frame `frame` of FRAMES: two belt lanes
    crossing (treads moving outward from the centre, toward the four corners), a diverter gear in
    the middle and four corner rollers, all looping."""
    t = frame / FRAMES
    z0 = H - PIT
    box(root, m["dark"], -WIN + 0.005, -WIN + 0.005, z0 - 0.01, WIN - 0.005, WIN - 0.005, z0 + 0.003, name="floor")
    lane_w = 0.17
    # each lane ends inside the opening, wrapping round a drum under its corner gear (the lane's
    # whole length shows; nothing is cut off by the opening's walls)
    half = 0.33
    for ang in (45, 135):
        ln = box(root, m["tread"], -half, -lane_w / 2, z0, half, lane_w / 2, z0 + 0.035, bev=0.008, name="lane")
        ln.rotation_euler = (0, 0, math.radians(ang))
        for sgn in (-1, 1):
            a = math.radians(ang)
            d = cyl(root, m["steel"], 0.024, lane_w + 0.02, segs=12, name="drum")
            d.location = (sgn * half * math.cos(a), sgn * half * math.sin(a), z0 + 0.018)
            d.rotation_mode = "ZXY"
            d.rotation_euler = (math.radians(90), 0, a)
    m["tread"].node_tree.nodes["offset"].outputs[0].default_value = 0.2 * t
    teeth = 10
    gear(root, m["light"], 0, 0, z0 + 0.075, 0.11, teeth, 0.035, 2 * math.pi * t / teeth, name="diverter")
    cap = cyl(root, m["accent"], 0.04, 0.02, segs=12, name="cap")
    cap.location = (0, 0, z0 + 0.11)
    for sx in (-1, 1):
        for sy in (-1, 1):
            g = gear(root, m["light"], sx * 0.24, sy * 0.24, z0 + 0.04, 0.06, 8,
                     0.025, -2 * math.pi * t / 8 * (1 if sx * sy > 0 else -1), name="small")


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


def hood(root, m, side, flow=None):
    """The port on the half of an edge tile toward its block (`side` of the tile), the round-5
    design: the belt runs on visibly under a raised roof (steel top, painted edges, a tier stripe,
    two ribs and a drive roller under its front edge) standing on two narrow side frames; the belt's
    own frame rails run out of it, and the belt under the roof is shaded darker toward the block,
    where the items go in. It grows out of the block's wall: a painted collar plate against the
    wall, bolted, carries the roof and the side frames. Items are hidden on the half tile next to
    the block; the roof reaches a quarter tile past the tile's middle (it shows 0.21 tile higher
    than its footprint) and a rubber curtain hangs in its mouth, so items come out from under it
    instead of appearing on the open belt. Two tier-coloured chevrons on the roof, like an
    underground belt's, point the way the items go (`flow` "in": toward the block, "out": away;
    None: no chevrons, for the shadow). Modelled with the block to the south ("s") and rotated."""
    g = group(root, "hood", math.radians({"s": 0, "n": 180, "e": 90, "w": -90}[side]))
    hw = 0.47
    y0, y1 = -0.5, 0.25
    hh = HOOD_H
    cy = y0 + 0.05  # the collar's face
    # collar: a frame around the belt opening in the block's wall, as tall as the roof plus a lintel
    box(g, m["body"], -0.47, y0, 0.0, 0.47, cy, hh + 0.07, bev=0.018, name="collar")
    box(g, m["dark"], -0.4, cy - 0.002, 0.0, 0.4, cy + 0.002, hh - 0.07, name="mouth")
    for x in (-0.44, 0.44):
        for z in (0.06, hh + 0.02):
            b = cyl(g, m["light"], 0.018, 0.02, segs=10, name="cbolt")
            b.location = (x, cy + 0.005, z)
            b.rotation_euler = (math.radians(90), 0, 0)
    box(g, m["body"], -hw, cy, hh - 0.06, hw, y1, hh, bev=0.02, name="roof")
    # roof panel, like a miniloader's top: a riveted rusty steel frame round a panel of wide
    # tier-coloured chevron bands with steel showing between them, edge to edge
    fw = 0.045
    px0, px1, py0, py1 = -hw + fw, hw - fw, cy + fw, y1 - fw
    for (a0, b0, a1, b1) in ((-hw, cy, hw, py0), (-hw, py1, hw, y1), (-hw, py0, px0, py1), (px1, py0, hw, py1)):
        box(g, m["steel"], a0, b0, hh - 0.01, a1, b1, hh + 0.016, bev=0.006, name="frame")
    for (a, b) in ((px0 - fw / 2, py0 - fw / 2), (px1 + fw / 2, py0 - fw / 2), (px0 - fw / 2, py1 + fw / 2),
                   (px1 + fw / 2, py1 + fw / 2), (0, py0 - fw / 2), (0, py1 + fw / 2),
                   (px0 - fw / 2, (py0 + py1) / 2), (px1 + fw / 2, (py0 + py1) / 2)):
        r = cyl(g, m["light"], 0.011, 0.012, segs=8, name="rivet")
        r.location = (a, b, hh + 0.02)
    if flow:
        sgn = 1 if flow == "out" else -1
        w = (px1 - px0) / 2
        rise, band, period = 0.14, 0.13, 0.19
        span = py1 - py0
        z0, z1 = hh, hh + 0.008
        k = -2
        while k * period < span + rise + period:
            # one chevron band (apex toward the flow), cut to the panel by construction
            for sx in (-1, 1):
                pts = []
                for x, yy in ((0.0, 0.0), (sx * w, -rise)):
                    pts.append((x, yy))
                c = py0 + k * period if sgn > 0 else py1 - k * period
                quad = [(0.0, c + sgn * band / 2), (sx * w, c - sgn * (rise - band / 2)),
                        (sx * w, c - sgn * (rise + band / 2)), (0.0, c - sgn * band / 2)]
                ys = [q[1] for q in quad]
                if max(ys) < py0 or min(ys) > py1:
                    continue
                quad = [(x, min(max(yy, py0), py1)) for x, yy in quad]
                bm = bmesh.new()
                top = [bm.verts.new((x, yy, z1)) for x, yy in quad]
                bot = [bm.verts.new((x, yy, z0)) for x, yy in quad]
                try:
                    bm.faces.new(top)
                    bm.faces.new(bot[::-1])
                    for i in range(4):
                        j = (i + 1) % 4
                        bm.faces.new((bot[i], bot[j], top[j], top[i]))
                except ValueError:
                    bm.free()
                    continue
                bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
                bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
                obj(bm, "chevron", m["paint"], g)
            k += 1
    roller(g, m["light"], 0, y1 - 0.02, hh - 0.09, 2 * hw - 0.14, 0.03, axis="X", name="drive")
    for sx in (-1, 1):
        x0, x1 = sorted((sx * hw, sx * (hw - 0.065)))
        box(g, m["paint"], x0, cy, 0.0, x1, y1, hh - 0.05, bev=0.012, name="cheek")
        hx = x0 - 0.002 if sx < 0 else x1 - 0.004
        box(g, m["dark"], hx, cy + 0.03, 0.07, hx + 0.006, y1 - 0.05, 0.15, name="hole")
    for sx in (-1, 1):
        rx = sx * 0.44
        box(g, m["steel"], rx - 0.025, y1, 0.0, rx + 0.025, 0.49, 0.05, bev=0.008, name="rail")
        for by in (y1 + 0.07, y1 + 0.17):
            b = cyl(g, m["light"], 0.014, 0.02, segs=8, name="bolt")
            b.location = (rx, by, 0.055)
    # rubber curtain in the mouth: strips hanging from under the roof to just above the items
    n = 7
    w = (2 * hw - 0.16) / n
    for k in range(n):
        sx0 = -hw + 0.08 + k * w
        box(g, m["rubber"], sx0 + 0.004, y1 - 0.03, 0.05, sx0 + w - 0.004, y1 - 0.015, hh - 0.06, bev=0.003,
            name="flap")
    gloom = gloom_material(0.22)
    gloom2 = gloom_material(0.35)
    # the belt darkens as it runs in under the roof toward the block
    box(g, gloom, -0.4, y0, 0.004, 0.4, y1, 0.008, name="gloom")
    box(g, gloom2, -0.4, y0, 0.009, 0.4, y1 - 0.15, 0.012, name="gloom2")
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
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0 if shadow else WORLD
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    root, ground, world = reset()
    keep = (root, ground)
    tiers = [t for t in TIERS if t in os.environ.get("MB_TIERS", ",".join(TIERS)).split(",")]
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
    housing(root, mats[tiers[0]]["body"], {(0, 0)}, H)
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
        hood(root, mats[tiers[0]], side)
        render(os.path.join(OUT, "hood-shadow-%s.png" % side), ground, world, shadow=True)
        for t in tiers:
            for flow in ("in", "out"):
                clear(keep)
                hood(root, mats[t], side, flow)
                render(os.path.join(OUT, "hood-%s-%s-%s.png" % (t, side, flow)), ground, world)
    print("RENDER DONE")


main()
