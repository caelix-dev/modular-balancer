-- Hidden entities of the balancing network, one set per belt tier. They live only on the hidden
-- surface (scripts/surface.lua) and are placed by scripts/builder.lua:
--   mb-hidden-splitter-<tier>       copy of the vanilla splitter of that tier
--   mb-hidden-linked-belt-<tier>    copy of `linked-belt` at the tier's belt speed; every network
--                                   edge is one pair of these (docs/feasibility.md F1, F2)
--   mb-hidden-lane-splitter-<tier>  copy of the vanilla `lane-splitter` (yellow speed in base) at
--                                   the tier's belt speed, for the balance-lanes option (F5)
-- Tiers: basic, fast, express, and turbo with Space Age.

local TIERS = {
  { name = "basic", belt = "transport-belt", splitter = "splitter" },
  { name = "fast", belt = "fast-transport-belt", splitter = "fast-splitter" },
  { name = "express", belt = "express-transport-belt", splitter = "express-splitter" },
}
---@diagnostic disable-next-line: unnecessary-if
if mods["space-age"] then
  TIERS[#TIERS + 1] = { name = "turbo", belt = "turbo-transport-belt", splitter = "turbo-splitter" }
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

local function hide(p, name, speed)
  p.name = name
  p.speed = speed
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

local protos = {}
for _, tier in ipairs(TIERS) do
  local speed = data.raw["transport-belt"][tier.belt].speed

  protos[#protos + 1] =
    hide(table.deepcopy(data.raw["splitter"][tier.splitter]), "mb-hidden-splitter-" .. tier.name, speed)

  local lb = hide(table.deepcopy(data.raw["linked-belt"]["linked-belt"]), "mb-hidden-linked-belt-" .. tier.name, speed)
  lb.allow_side_loading = false
  lb.allow_clone_connection = false
  lb.allow_blueprint_connection = false
  protos[#protos + 1] = lb

  protos[#protos + 1] =
    hide(table.deepcopy(data.raw["lane-splitter"]["lane-splitter"]), "mb-hidden-lane-splitter-" .. tier.name, speed)
end

data:extend(protos)
