-- Builds the screenshot scenes on nauvis (Plan 3 Task 4): per tier, the user's L-shape
-- (5 blocks in a row plus one bent down, 2 inputs from above, 6 outputs) at (40 i, 0) and a 1x8
-- row (8 inputs above, 3 outputs below) at (40 i, 30). Sources are infinity chests with tier
-- loaders, sinks are tier loaders into infinity chests that delete everything. Safe map:
-- peaceful mode, enemies removed, the character (when one exists) invulnerable.
-- Paste as the body of an fdev `exec_lua` call (Space Age preset for the turbo tier), run a few
-- thousand ticks (the hidden networks fill first), run tidy-scene.lua after `gui_connect` (the
-- freeplay crash site lands when the player joins).
local s = game.surfaces.nauvis
local D = defines.direction
s.peaceful_mode = true
game.forces.enemy.kill_all_units()
for _, e in pairs(s.find_entities_filtered({ force = "enemy" })) do
  e.destroy()
end
s.always_day = true
local TIERS = {
  { "basic", "transport-belt", "loader" },
  { "fast", "fast-transport-belt", "fast-loader" },
  { "express", "express-transport-belt", "express-loader" },
  { "turbo", "turbo-transport-belt", "turbo-loader" },
}
local area = { { -10, -20 }, { 40 * #TIERS + 10, 50 } }
s.request_to_generate_chunks({ 80, 15 }, 6)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered({ area = area })) do
  if e.type ~= "character" then
    e.destroy()
  end
end
s.destroy_decoratives({ area = area })
local tiles = {}
for x = area[1][1], area[2][1] do
  for y = area[1][2], area[2][2] do
    tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } }
  end
end
s.set_tiles(tiles)

local VEC = { [D.north] = { 0, -1 }, [D.south] = { 0, 1 }, [D.east] = { 1, 0 }, [D.west] = { -1, 0 } }
local function ce(t)
  t.force = "player"
  local e = s.create_entity(t)
  assert(e, "could not create " .. t.name)
  return e
end
-- a source: chest, loader, then `n` belt tiles ending at (x, y), all running in `dir`
local function source(tier, x, y, dir, n)
  local v = VEC[dir]
  for k = 0, n - 1 do
    ce({ name = tier[2], position = { x - v[1] * k + 0.5, y - v[2] * k + 0.5 }, direction = dir })
  end
  local lx, ly = x - v[1] * (n + 0.5), y - v[2] * (n + 0.5)
  ce({ name = tier[3], position = { lx + 0.5, ly + 0.5 }, direction = dir, type = "output" })
  local chest = ce({ name = "infinity-chest", position = { x - v[1] * (n + 2) + 0.5, y - v[2] * (n + 2) + 0.5 } })
  chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
end
-- a sink: `n` belt tiles from (x, y) running in `dir`, then a loader into a deleting chest
local function sink(tier, x, y, dir, n)
  local v = VEC[dir]
  for k = 0, n - 1 do
    ce({ name = tier[2], position = { x + v[1] * k + 0.5, y + v[2] * k + 0.5 }, direction = dir })
  end
  local lx, ly = x + v[1] * (n + 0.5), y + v[2] * (n + 0.5)
  ce({ name = tier[3], position = { lx + 0.5, ly + 0.5 }, direction = dir, type = "input" })
  local chest = ce({ name = "infinity-chest", position = { x + v[1] * (n + 2) + 0.5, y + v[2] * (n + 2) + 0.5 } })
  chest.remove_unfiltered_items = true
end
for i, tier in ipairs(TIERS) do
  local block = "mb-balancer-" .. tier[1]
  local ox = 40 * (i - 1)
  -- L-shape
  for x = 0, 4 do
    ce({ name = block, position = { ox + x + 0.5, 0.5 } })
  end
  ce({ name = block, position = { ox + 4.5, 1.5 } })
  source(tier, ox + 0, -1, D.south, 3)
  source(tier, ox + 1, -1, D.south, 3)
  for x = 0, 3 do
    sink(tier, ox + x, 1, D.south, 3)
  end
  sink(tier, ox + 4, 2, D.south, 2)
  sink(tier, ox + 5, 1, D.east, 3)
  -- 1x8 row
  for x = 0, 7 do
    ce({ name = block, position = { ox + x + 0.5, 30.5 } })
    source(tier, ox + x, 29, D.south, 3)
  end
  for _, x in ipairs({ 1, 4, 6 }) do
    sink(tier, ox + x, 31, D.south, 3)
  end
  -- a vanilla splitter next to the L-shape, for scale
  local sname = tier[2]:gsub("transport%-belt", "splitter")
  ce({ name = sname, position = { ox + 13, 0.5 }, direction = D.south })
  source(tier, ox + 12, -1, D.south, 3)
  source(tier, ox + 13, -1, D.south, 3)
  sink(tier, ox + 12, 1, D.south, 3)
  sink(tier, ox + 13, 1, D.south, 3)
end
-- built without events: raise them for the blocks now, so the balancers pick their belts up
for _, e in pairs(s.find_entities_filtered({ area = area, type = "simple-entity-with-owner" })) do
  script.raise_script_built({ entity = e })
end
for _, p in pairs(game.players) do
  if p.character then
    p.character.destructible = false
  end
end
return "ok"
