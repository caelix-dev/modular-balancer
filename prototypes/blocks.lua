-- The visible balancer blocks, one per belt tier: entity, item and recipe `mb-balancer-<tier>`.
-- Tiers: basic, fast, express, and turbo (hidden, without a recipe, when Space Age is absent).
--
-- The block is a `simple-entity-with-owner`, not a belt-connectable entity, with the collision
-- layer item only (docs/feasibility.md F1 "Chosen design", later without player and is_object):
-- its tile can then also hold one hidden linked belt (the F1 block-tile interface or the F3 belt
-- port), which every belt-connectable must collide with. It still collides with buildings,
-- inserters, rails, trees, cliffs, water and other blocks; like a belt it has neither the player
-- nor the is_object layer, so characters and vehicles move over it.
--
-- Recipe: the tier's splitter plus 5 of the tier's belts, unlocked by the technology that
-- unlocks the tier's splitter. Graphics and icon: original sprites, coloured per tier like the
-- vanilla belts (see below); the port hoods over the edges are drawn by the edges themselves
-- (prototypes/hidden.lua).
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

local look = require("scripts.look")

local function raw(kind, name)
  local p = data.raw[kind] and data.raw[kind][name]
  if not p then
    error("modular-balancer: prototype " .. kind .. "/" .. name .. " is missing")
  end
  return p
end

-- Graphics: Blender renders (tools/render/), sprite set chosen in prototypes/gfx.lua. One sheet
-- per tier with 47 frames, one per connected neighbourhood (scripts/look.lua: a group reads as one
-- machine, its rounded frame only around the outline), plus a shared shadow sheet. The tile is
-- centred in each frame; the housing shows above its footprint and the shadow falls to the right.
local GFX = "__modular-balancer__/graphics/"
local gfx = require("prototypes.gfx")
local FRAMES = #look.masks()

-- One Animation per neighbourhood: that frame of the static sheet (held for the whole loop with
-- repeat_count), the machinery loop in the top opening (the same 16 frames for every
-- neighbourhood) and the shadow. A prototype animation: no script runs for it.
local ANIM_FRAMES = 16
local function animations(colour)
  local list = {}
  for i = 1, FRAMES do
    local x = ((i - 1) % 8) * gfx.frame
    local y = math.floor((i - 1) / 8) * gfx.frame
    local function still(file, shadow)
      return {
        filename = gfx.dir .. file,
        priority = "high",
        width = gfx.frame,
        height = gfx.frame,
        x = x,
        y = y,
        frame_count = 1,
        repeat_count = ANIM_FRAMES,
        scale = gfx.scale,
        draw_as_shadow = shadow or nil,
      }
    end
    list[i] = {
      layers = {
        still("balancer-" .. colour .. ".png"),
        {
          filename = gfx.dir .. "machinery-" .. colour .. ".png",
          priority = "high",
          width = gfx.frame,
          height = gfx.frame,
          frame_count = ANIM_FRAMES,
          line_length = 8,
          animation_speed = 0.4,
          scale = gfx.scale,
        },
        still("balancer-shadow.png", true),
      },
    }
  end
  return list
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
  local colour = tier.orphan and "express" or tier.name
  local icons = { { icon = GFX .. "icons/balancer-" .. colour .. ".png", icon_size = 64 } }

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
    collision_mask = { layers = { item = true } },
    fast_replaceable_group = "mb-balancer",
    next_upgrade = next_tier and ("mb-balancer-" .. next_tier.name) or nil,
    render_layer = "object",
    animations = animations(colour),
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
