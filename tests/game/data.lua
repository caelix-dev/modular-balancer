-- Test harness prototypes for the in-game suites (tests/game/). Loaded from data.lua only with the
-- dev gate `mb-dev` (settings.lua: factorio-test and the dev marker tests/dev.lua, which release
-- zips leave out); never part of the product.
--   mb-test-loader-<tier>  loader-1x1 at the belt speed of basic / fast / express (/ turbo)
--   mb-test-loader-half    loader-1x1 at half the express belt speed (a throttled sink)
--   mb-test-chest          a large chest, used as a finite source and as a counting sink
--   mb-test-inserter       a bulk inserter that needs no power
--   mb-test-roboport       a roboport that needs no power (robot builds in tests/game/groups.lua)
--   mb-test-block          stand-in for the visible block: not belt-connectable, so a belt
--                          port (a linked belt) can share its tile (docs/feasibility.md F1, F3)

local BELTS = {
  basic = "transport-belt",
  fast = "fast-transport-belt",
  express = "express-transport-belt",
  turbo = mods["space-age"] and "turbo-transport-belt" or nil,
}

local protos = {}

local function loader(name, speed)
  local p = table.deepcopy(data.raw["loader-1x1"]["loader-1x1"])
  p.name = name
  p.speed = speed
  p.minable = nil
  protos[#protos + 1] = p
end
for tier, belt in pairs(BELTS) do
  loader("mb-test-loader-" .. tier, data.raw["transport-belt"][belt].speed)
end
loader("mb-test-loader-half", data.raw["transport-belt"]["express-transport-belt"].speed / 2)

local chest = table.deepcopy(data.raw["container"]["steel-chest"])
chest.name = "mb-test-chest"
chest.inventory_size = 1000
chest.minable = nil
protos[#protos + 1] = chest

local inserter = table.deepcopy(data.raw["inserter"]["bulk-inserter"])
inserter.name = "mb-test-inserter"
inserter.energy_source = { type = "void" }
inserter.minable = nil
inserter.next_upgrade = nil
protos[#protos + 1] = inserter

local block = table.deepcopy(data.raw["simple-entity-with-owner"]["simple-entity-with-owner"])
block.name = "mb-test-block"
block.collision_mask = { layers = { item = true, player = true, is_object = true } }
block.minable = nil
protos[#protos + 1] = block

local roboport = table.deepcopy(data.raw["roboport"]["roboport"])
roboport.name = "mb-test-roboport"
roboport.energy_source = { type = "void" }
roboport.minable = nil
roboport.next_upgrade = nil
protos[#protos + 1] = roboport

data:extend(protos)
