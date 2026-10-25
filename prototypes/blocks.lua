-- The visible balancer blocks, one per belt tier: entity, item and recipe `mb-balancer-<tier>`.
-- Tiers: basic, fast, express, and turbo (hidden, without a recipe, when Space Age is absent).
--
-- The block is a `simple-entity-with-owner`, not a belt-connectable entity, with the collision
-- layers item, player and is_object only (docs/feasibility.md F1 "Chosen design"): its tile can
-- then also hold one hidden linked belt (the F1 block-tile interface or the F3 belt port), which
-- every belt-connectable must collide with. It still collides with buildings, inserters, the
-- character and water.
--
-- Recipe: the tier's splitter plus 5 of the tier's belts, unlocked by the technology that
-- unlocks the tier's splitter. Icon: the tier splitter's. Graphics: see the candidates below
-- (cut from the tier splitter's housing, so coloured per tier like the vanilla belts).
-- `next_upgrade` chains the tiers for the upgrade planner.
-- Required from data.lua.

---@type { name: string, belt: string, splitter: string, orphan: boolean? }[]
local TIERS = {
  { name = "basic", belt = "transport-belt", splitter = "splitter" },
  { name = "fast", belt = "fast-transport-belt", splitter = "fast-splitter" },
  { name = "express", belt = "express-transport-belt", splitter = "express-splitter" },
}
-- Turbo needs Space Age. Without it the turbo block still exists, hidden and without a recipe
-- (express graphics), so a save with turbo balancers loads after Space Age is removed: the game
-- deletes every entity of a removed prototype, and control.lua downgrades these blocks to express
-- instead, items kept (scripts/lifecycle.lua).
---@diagnostic disable-next-line: unnecessary-if
if data.raw["transport-belt"]["turbo-transport-belt"] then
  TIERS[#TIERS + 1] = { name = "turbo", belt = "turbo-transport-belt", splitter = "turbo-splitter" }
else
  TIERS[#TIERS + 1] = { name = "turbo", belt = "express-transport-belt", splitter = "express-splitter", orphan = true }
end

-- Block graphics candidates (Plan 3 Task 4), picked by the hidden startup setting `mb-look`:
--   bank   one unit of the tier splitter's housing per block, belts visible under it (the tier
--          belt runs under the housing on the sides with a port);
--   solid  a full-tile housing: tier band along the top, machinery, the tier splitter's coloured
--          front face along the bottom;
--   hood   `solid`, and the housing reaches half a tile over each port belt (it covers the half
--          tile where items vanish into or come out of the block).
-- Everything is cut from the tier splitter's own sheets (`structure.north` and `structure.south`,
-- frame 1) and the tier belt's sheet by reference: no new image files. Neighbouring blocks read
-- as one machine: the entity has 81 graphics variations, one per neighbourhood, and the block's
-- variation is
--   1 + n + 3 e + 9 s + 27 w,  side state 0 = open, 1 = a block of the same group, 2 = a port
-- (an edge `mb-edge-*` on that side). Variation 1 (a lone block) is the default; picking the
-- variation at build time is left for after the user's choice (the candidate screenshots set it
-- with docs/plan3/candidates/apply-variations.lua).
local LOOK = settings.startup["mb-look"].value
local U = 1 / 64 -- one unit: 1/64 tile, one source pixel at the vanilla scale 0.5
local OPEN, JOINED, PORT = 0, 1, 2
local SIDES = { "n", "e", "s", "w" }
local EMPTY = { filename = "__core__/graphics/empty.png", size = 1, priority = "extra-high" }

local function raw(kind, name)
  local p = data.raw[kind] and data.raw[kind][name]
  if not p then
    error("modular-balancer: prototype " .. kind .. "/" .. name .. " is missing")
  end
  return p
end

-- A plain single-file animation sheet (frame 1 sits at x, y), or nil.
local function sheet(anim)
  if not anim or anim.layers or anim.stripes or anim.filenames or not anim.filename then
    return nil
  end
  local size = anim.size
  local w = anim.width or (type(size) == "table" and size[1]) or size
  local h = anim.height or (type(size) == "table" and size[2]) or size
  if type(w) ~= "number" or type(h) ~= "number" then
    return nil
  end
  local shift = anim.shift or { 0, 0 }
  return {
    filename = anim.filename,
    x = anim.x or 0,
    y = anim.y or 0,
    width = w,
    height = h,
    scale = anim.scale or 1,
    sx = shift[1] or shift.x or 0,
    sy = shift[2] or shift.y or 0,
  }
end

-- The tier splitter's north and south housing sheets (the vanilla splitter's when not plain).
local function housing(splitter)
  local st = splitter.structure or {}
  local n, s = sheet(st.north), sheet(st.south)
  if n and s then
    return n, s
  end
  local base = raw("splitter", "splitter").structure
  return sheet(base.north) --[[@as table]], sheet(base.south) --[[@as table]]
end

-- Part of a sheet's frame 1, given in units relative to the splitter's centre (x0..x1, y0..y1),
-- drawn with its top-left corner at (tx, ty) units from the block's centre. Clamped to the frame.
local function cut(f, x0, x1, y0, y1, tx, ty)
  local k = 32 / f.scale * U -- source pixels per unit
  local cx, cy = f.width / 2 - f.sx * 32 / f.scale, f.height / 2 - f.sy * 32 / f.scale
  local px0 = math.floor(cx + x0 * k + 0.5)
  local px1 = math.floor(cx + x1 * k + 0.5)
  local py0 = math.floor(cy + y0 * k + 0.5)
  local py1 = math.floor(cy + y1 * k + 0.5)
  local cl, cr = math.max(px0, 0), math.min(px1, f.width)
  local ct, cb = math.max(py0, 0), math.min(py1, f.height)
  if cr <= cl or cb <= ct then
    return nil
  end
  local w, h = cr - cl, cb - ct
  local left = (tx + (cl - px0) / k) * U
  local top = (ty + (ct - py0) / k) * U
  return {
    filename = f.filename,
    priority = "extra-high",
    x = f.x + cl,
    y = f.y + ct,
    width = w,
    height = h,
    scale = f.scale,
    shift = { left + w / k * U / 2, top + h / k * U / 2 },
  }
end

-- Housing columns (units, relative to the splitter's centre): the left unit's outer and inner
-- halves, the right unit's inner and outer halves, and the right unit's side shadow.
local LCAP, LIN, RIN, RCAP, RSHADOW = { -64, -32 }, { -32, 0 }, { 0, 32 }, { 32, 64 }, { 64, 92 }
-- Housing rows (units): the tier band on top and the machinery under it (north sheet), the whole
-- bar (north sheet), and the coloured front face (south sheet).
local BAND, BODY, BAR, FACE = { -31, -11 }, { -11, 15 }, { -31, 35 }, { -4, 32 }

-- Columns of a box spanning l..r units (32-unit steps), with or without its outer ends.
-- Inner halves alternate so the notch between two splitter units falls on tile borders.
local function columns(l, r, cap_w, cap_e)
  local cols = {}
  for x = l, r - 32, 32 do
    local src
    if x == l and cap_w then
      src = LCAP
    elseif x == r - 32 and cap_e then
      src = RCAP
    elseif (x % 64) == 32 then
      src = RIN
    else
      src = LIN
    end
    cols[#cols + 1] = { x = x, src = src }
    if x == r - 32 and cap_e then
      cols[#cols + 1] = { x = x + 32, src = RSHADOW, shadow = true }
    end
  end
  return cols
end

-- A solid housing box l..r, t..b (units from the block's centre); `cap` says which sides are
-- outer sides (band on top, front face at the bottom, end caps left and right).
local function box(layers, n, s, l, r, t, b, cap)
  local cols = columns(l, r, cap.w, cap.e)
  local top = cap.n and t + 16 or t ---@type number
  local bottom = cap.s and b - 20 or b ---@type number
  for _, c in ipairs(cols) do
    local w = c.src[2] - c.src[1]
    local y = top
    while y < bottom do
      local h = BODY[2] - BODY[1] ---@type number
      if bottom - y < h then
        h = bottom - y
      end
      if not c.shadow or y == top then
        layers[#layers + 1] = cut(n, c.src[1], c.src[1] + w, BODY[1], BODY[1] + h, c.x, y) or false
      end
      y = y + h
    end
    if cap.n then
      layers[#layers + 1] = cut(n, c.src[1], c.src[1] + w, BAND[1], BAND[2], c.x, t - 4) or false
    end
  end
  if cap.s then
    for _, c in ipairs(cols) do
      local w = c.src[2] - c.src[1]
      layers[#layers + 1] = cut(s, c.src[1], c.src[1] + w, FACE[1], FACE[2], c.x, b - 32) or false
    end
  end
end

-- Part (l..l+w, t..t+h units of the tile) of the tier belt's straight frame 1 for a direction.
local DEFAULT_INDEX = { east = 1, west = 2, north = 3, south = 4 }
local function belt_part(belt, dir, l, t, w, h)
  local set = belt.belt_animation_set
  local f = set and sheet(set.animation_set)
  if not f then
    return false
  end
  local row = (set[dir .. "_index"] or DEFAULT_INDEX[dir]) - 1
  local k = 32 / f.scale * U
  local ox = f.x + f.width / 2 - 32 * k
  local oy = f.y + row * f.height + f.height / 2 - 32 * k
  return {
    filename = f.filename,
    priority = "extra-high",
    x = math.floor(ox + (l + 32) * k + 0.5),
    y = math.floor(oy + (t + 32) * k + 0.5),
    width = math.floor(w * k + 0.5),
    height = math.floor(h * k + 0.5),
    scale = f.scale,
    shift = { (l + w / 2) * U, (t + h / 2) * U },
  }
end

local function compact(layers)
  local out = {}
  for _, layer in ipairs(layers) do
    if layer then
      out[#out + 1] = layer
    end
  end
  return out
end

-- The variation for one neighbourhood { n = state, e = ..., s = ..., w = ... }.
local function variation(n, s, belt, st)
  local layers, lower = {}, {}
  local function closed(side)
    return st[side] ~= JOINED
  end
  if LOOK == "bank" then
    -- the tier belt under the housing on port sides (north-south first), then one splitter unit
    if st.n == PORT or st.s == PORT then
      lower[#lower + 1] = belt_part(belt, "south", -32, -32, 64, 64)
    elseif st.e == PORT or st.w == PORT then
      lower[#lower + 1] = belt_part(belt, "east", -32, -32, 64, 64)
    end
    for _, c in ipairs(columns(-32, 32, closed("w"), closed("e"))) do
      local w = c.src[2] - c.src[1]
      layers[#layers + 1] = cut(n, c.src[1], c.src[1] + w, BAR[1], BAR[2], c.x, -33) or false
    end
  else
    local hood = LOOK == "hood"
    local function shut(side)
      return st[side] == OPEN or (st[side] == PORT and not hood)
    end
    box(layers, n, s, -32, 32, -32, 32, { n = shut("n"), e = shut("e"), s = shut("s"), w = shut("w") })
    if hood then
      -- half a tile of housing over each port belt, outer on its three free sides
      if st.n == PORT then
        box(layers, n, s, -32, 32, -64, -32, { n = true, e = true, s = false, w = true })
      end
      if st.s == PORT then
        box(layers, n, s, -32, 32, 32, 64, { n = false, e = true, s = true, w = true })
      end
      if st.w == PORT then
        box(layers, n, s, -64, -32, -32, 32, { n = true, e = false, s = true, w = true })
      end
      if st.e == PORT then
        box(layers, n, s, 32, 64, -32, 32, { n = true, e = true, s = true, w = false })
      end
    end
  end
  layers, lower = compact(layers), compact(lower)
  return { layers = layers }, { layers = #lower > 0 and lower or { EMPTY } }
end

-- All 81 variations of a tier's block: pictures, lower_pictures.
local function pictures(splitter, belt)
  local n, s = housing(splitter)
  local pics, lows = {}, {}
  for i = 0, 80 do
    local st, v = {}, i
    for _, side in ipairs(SIDES) do
      st[side] = v % 3
      v = math.floor(v / 3)
    end
    pics[i + 1], lows[i + 1] = variation(n, s, belt, st)
  end
  return pics, lows
end

local function icons_of(item)
  if item.icons then
    return table.deepcopy(item.icons)
  end
  return { { icon = item.icon, icon_size = item.icon_size } }
end

-- The effects list of the technology that unlocks `recipe`, or nil.
local function unlocking_effects(recipe)
  for _, tech in pairs(data.raw.technology) do
    local effects = tech.effects or {}
    for _, effect in ipairs(effects) do
      if effect.type == "unlock-recipe" and effect.recipe == recipe then
        return effects
      end
    end
  end
  return nil
end

local protos = {}
local function add_recipe(name, tier)
  local recipe = {
    type = "recipe",
    name = name,
    enabled = false,
    energy_required = 1,
    ingredients = {
      { type = "item", name = tier.splitter, amount = 1 },
      { type = "item", name = tier.belt, amount = 5 },
    },
    results = { { type = "item", name = name, amount = 1 } },
  }
  protos[#protos + 1] = recipe

  local effects = unlocking_effects(tier.splitter)
  if effects then
    effects[#effects + 1] = { type = "unlock-recipe", recipe = name }
  else
    -- No technology unlocks the splitter (an overhaul mod): follow the splitter recipe.
    local sr = data.raw.recipe[tier.splitter]
    recipe.enabled = sr == nil or sr.enabled ~= false
  end
end

for i, tier in ipairs(TIERS) do
  local name = "mb-balancer-" .. tier.name
  local splitter = raw("splitter", tier.splitter)
  local splitter_item = raw("item", tier.splitter)
  local next_tier = TIERS[i + 1]
  if next_tier and next_tier.orphan then
    next_tier = nil
  end
  local icons = icons_of(splitter_item)
  local pics, lows = pictures(splitter, raw("transport-belt", tier.belt))

  protos[#protos + 1] = {
    type = "simple-entity-with-owner",
    name = name,
    icons = icons,
    flags = { "placeable-neutral", "player-creation" },
    minable = { mining_time = 0.1, result = name },
    max_health = splitter.max_health or 170,
    corpse = splitter.corpse,
    dying_explosion = splitter.dying_explosion,
    resistances = table.deepcopy(splitter.resistances),
    collision_box = { { -0.4, -0.4 }, { 0.4, 0.4 } },
    selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
    collision_mask = { layers = { item = true, player = true, is_object = true } },
    fast_replaceable_group = "mb-balancer",
    next_upgrade = next_tier and ("mb-balancer-" .. next_tier.name) or nil,
    render_layer = "object",
    pictures = pics,
    lower_pictures = lows,
    lower_render_layer = "transport-belt",
    random_variation_on_create = false,
    hidden = tier.orphan or nil,
    hidden_in_factoriopedia = tier.orphan or nil,
  }

  protos[#protos + 1] = {
    type = "item",
    name = name,
    icons = icons,
    subgroup = splitter_item.subgroup or "belt",
    order = (splitter_item.order or "c") .. "-mb[" .. i .. "]",
    inventory_move_sound = splitter_item.inventory_move_sound,
    pick_sound = splitter_item.pick_sound,
    drop_sound = splitter_item.drop_sound,
    place_result = name,
    stack_size = 50,
    hidden = tier.orphan or nil,
    hidden_in_factoriopedia = tier.orphan or nil,
  }

  -- recipe and technology unlock (none for the hidden turbo block without Space Age)
  if not tier.orphan then
    add_recipe(name, tier)
  end
end

data:extend(protos)
