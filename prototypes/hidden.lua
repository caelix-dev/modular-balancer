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
-- Tiers: basic, fast, express, and turbo with Space Age.
--
-- Required from data-final-fixes.lua, so every speed is read from the final belt prototype: a
-- mod that changes a belt's speed in data-updates or in an earlier data-final-fixes also
-- changes the hidden entities of that tier (final review M3).

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
  local speed = raw("transport-belt", tier.belt).speed

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

data:extend(protos)
