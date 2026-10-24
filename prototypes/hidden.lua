-- Hidden entities of the balancing network, one set per belt tier. They live only on the hidden
-- surface (scripts/surface.lua) and are placed by scripts/builder.lua:
--   mb-hidden-splitter-<tier>       copy of the vanilla splitter of that tier; also the priority
--                                   splitter (splitter_output_priority is set at runtime)
--   mb-hidden-linked-belt-<tier>    copy of `linked-belt`; every network edge is one pair of these
--                                   (docs/feasibility.md F1, F2)
--   mb-hidden-lane-splitter-<tier>  copy of the vanilla `lane-splitter` (yellow speed in base),
--                                   for the balance-lanes option (F5)
--   mb-hidden-loader-<tier>         loader-1x1 that drains the network's buffer chest
--   mb-hidden-never                 an item that never exists: the splitter filter that closes a
--                                   splitter's dead-end output (scripts/builder.lua). It is
--                                   hidden and has no recipe; only a cheat (a console insert, an
--                                   editor filter) can create it. Such an item takes the closed
--                                   side and jams that splitter lane; builder.contents and
--                                   builder.rebuild drop it, so the next rebuild clears the jam
--   mb-hidden-buffer                the buffer chest (one per network) that holds what a rebuild
--                                   could not put back on the belts; its size is set per network
--                                   at runtime with set_inventory_size_override
-- On nauvis (the player's side), scripts/io.lua places:
--   mb-hidden-linked-belt-<tier>    also the block-tile interface and the inserter belt port (F1,
--                                   F3), on a block's own tile under the block
--   mb-edge-in-<belt>, mb-edge-out-<belt>
--                                   edges (F1): one input and one output linked belt per
--                                   transport-belt prototype (modded belts included), at that
--                                   belt's speed, with its belt animation, mining and placing as
--                                   that belt. The last tile of a player belt that points into a
--                                   block (input) or leaves it (output) is swapped for one. Input
--                                   edges allow side loading like the belt they replace; output
--                                   edges do not. Own fast-replace group, so a belt cannot be
--                                   dragged over an edge. They keep the vanilla linked-belt
--                                   structure (a hatch) for now; Plan 3 gives them a plain belt look
-- Tiers: basic, fast, express and turbo (see TIERS).
--
-- Required from data-final-fixes.lua, so every speed is read from the final belt prototype: a
-- mod that changes a belt's speed in data-updates or in an earlier data-final-fixes also
-- changes the hidden entities of that tier (final review M3).

---@type { name: string, belt: string, splitter: string, speed: number? }[]
local TIERS = {
  { name = "basic", belt = "transport-belt", splitter = "splitter" },
  { name = "fast", belt = "fast-transport-belt", splitter = "fast-splitter" },
  { name = "express", belt = "express-transport-belt", splitter = "express-splitter" },
}
-- The turbo tier exists even without Space Age, so a save with turbo balancers keeps their hidden
-- networks (and the items on them) when Space Age is removed: the game would otherwise delete
-- every entity of a removed prototype with its items. Without the turbo belt it copies the
-- express entities at TURBO_SPEED, and control.lua downgrades the turbo blocks to express
-- (scripts/lifecycle.lua).
local TURBO_SPEED = 0.125 -- the Space Age turbo belt (60 items/s)
---@diagnostic disable-next-line: unnecessary-if
if data.raw["transport-belt"]["turbo-transport-belt"] then
  TIERS[#TIERS + 1] = { name = "turbo", belt = "turbo-transport-belt", splitter = "turbo-splitter" }
else
  TIERS[#TIERS + 1] = { name = "turbo", belt = "express-transport-belt", splitter = "express-splitter", speed = TURBO_SPEED }
end

-- `hidden` is a PrototypeBase property in 2.1, not an entity flag.
local FLAGS = {
  "not-blueprintable",
  "not-deconstructable",
  "not-on-map",
  "no-copy-paste",
  "not-selectable-in-game",
  "not-upgradable",
}

local function hide(p, name)
  p.name = name
  p.flags = table.deepcopy(FLAGS)
  p.hidden = true
  p.hidden_in_factoriopedia = true
  p.minable = nil
  p.placeable_by = nil
  p.next_upgrade = nil
  p.fast_replaceable_group = nil
  p.allow_copy_paste = false
  return p
end

local function raw(kind, name)
  local p = data.raw[kind] and data.raw[kind][name]
  if not p then
    error("modular-balancer: prototype " .. kind .. "/" .. name .. " is missing")
  end
  return p
end

local protos = {}
for _, tier in ipairs(TIERS) do
  local speed = tier.speed or raw("transport-belt", tier.belt).speed

  local sp = hide(table.deepcopy(raw("splitter", tier.splitter)), "mb-hidden-splitter-" .. tier.name)
  sp.speed = speed
  protos[#protos + 1] = sp

  local lb = hide(table.deepcopy(raw("linked-belt", "linked-belt")), "mb-hidden-linked-belt-" .. tier.name)
  lb.speed = speed
  lb.allow_side_loading = false
  lb.allow_clone_connection = false
  lb.allow_blueprint_connection = false
  protos[#protos + 1] = lb

  local ls = hide(table.deepcopy(raw("lane-splitter", "lane-splitter")), "mb-hidden-lane-splitter-" .. tier.name)
  ls.speed = speed
  protos[#protos + 1] = ls

  local loader = hide(table.deepcopy(raw("loader-1x1", "loader-1x1")), "mb-hidden-loader-" .. tier.name)
  loader.speed = speed
  protos[#protos + 1] = loader
end

local buffer = hide(table.deepcopy(raw("container", "steel-chest")), "mb-hidden-buffer")
-- A loader only takes from a container with "player-creation" (measured: a steel chest without
-- it, or with only "placeable-neutral", gets no loader_container).
buffer.flags[#buffer.flags + 1] = "player-creation"
buffer.inventory_size = 1
buffer.quality_affects_inventory_size = false
protos[#protos + 1] = buffer

local never = table.deepcopy(raw("item", "iron-plate"))
never.name = "mb-hidden-never"
never.hidden = true
never.hidden_in_factoriopedia = true
never.place_result = nil
never.fuel_value = nil
never.fuel_categories = nil
never.spoil_result = nil
never.spoil_ticks = nil
never.subgroup = nil
never.order = "z"
protos[#protos + 1] = never

-- Edges, one input and one output per transport belt (docs/feasibility.md F1).
local base_edge = raw("linked-belt", "linked-belt")
for _, belt in pairs(data.raw["transport-belt"]) do
  for _, role in ipairs({ "in", "out" }) do
    local e = table.deepcopy(base_edge)
    e.name = "mb-edge-" .. role .. "-" .. belt.name
    e.localised_name = belt.localised_name and table.deepcopy(belt.localised_name) or { "entity-name." .. belt.name }
    e.localised_description = nil
    e.icons = belt.icons and table.deepcopy(belt.icons) or { { icon = belt.icon, icon_size = belt.icon_size } }
    e.icon = nil
    e.icon_size = nil
    e.speed = belt.speed
    e.belt_animation_set = table.deepcopy(belt.belt_animation_set) or e.belt_animation_set
    e.allow_side_loading = role == "in"
    e.allow_clone_connection = false
    e.allow_blueprint_connection = false
    e.minable = belt.minable and table.deepcopy(belt.minable) or nil
    local item = belt.minable and belt.minable.result
    e.placeable_by = item and { item = item, count = 1 } or nil
    e.max_health = belt.max_health
    e.resistances = table.deepcopy(belt.resistances)
    e.next_upgrade = nil
    e.fast_replaceable_group = "mb-edge"
    e.hidden = true
    e.hidden_in_factoriopedia = true
    protos[#protos + 1] = e
  end
end

data:extend(protos)
