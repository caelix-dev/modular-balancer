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
-- unlocks the tier's splitter. Placeholder graphics (final graphics are Plan 3): the tier
-- splitter's icon, and the first frame of the tier splitter's north-facing housing scaled down
-- to one tile (already coloured per tier like the vanilla belts).
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

-- The splitter housing is 2.5 tiles wide at its own scale; this fits it into one tile.
local SHRINK = 0.4

local function raw(kind, name)
  local p = data.raw[kind] and data.raw[kind][name]
  if not p then
    error("modular-balancer: prototype " .. kind .. "/" .. name .. " is missing")
  end
  return p
end

-- First frame of an Animation (or its layers) as a Sprite scaled by SHRINK, or nil when the
-- animation is not a plain sheet (stripes or several files).
local function first_frame(anim)
  if anim.layers then
    local layers = {}
    for _, layer in ipairs(anim.layers) do
      local s = first_frame(layer)
      if not s then
        return nil
      end
      layers[#layers + 1] = s
    end
    return { layers = layers }
  end
  if not anim.filename then
    return nil
  end
  local shift = anim.shift or { 0, 0 }
  local sx, sy = shift[1] or shift.x or 0, shift[2] or shift.y or 0
  return {
    filename = anim.filename,
    priority = anim.priority,
    width = anim.width or (type(anim.size) == "table" and anim.size[1] or anim.size),
    height = anim.height or (type(anim.size) == "table" and anim.size[2] or anim.size),
    x = anim.x,
    y = anim.y,
    shift = { sx * SHRINK, sy * SHRINK },
    scale = (anim.scale or 1) * SHRINK,
    tint = anim.tint,
    draw_as_shadow = anim.draw_as_shadow,
  }
end

local function picture(splitter)
  local s = splitter.structure and splitter.structure.north and first_frame(splitter.structure.north)
  return s or first_frame(raw("splitter", "splitter").structure.north)
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
    picture = picture(splitter),
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
