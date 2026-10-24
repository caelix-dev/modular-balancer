-- Save/load check (save_load_keeps_items) as a remote interface, so it can run on an MCP fdev
-- server instance with factorio-test in portal_mods (FactorioTest cannot reload a save):
--   exec_lua: return remote.call("mb-test", "build")   -- a 3:5 rig with 3 x 1000 plates
--   run_ticks 600; exec_lua: return remote.call("mb-test", "block", true)  -- optional
--   exec_lua: return remote.call("mb-test", "count")   -- before the save
--   exec_lua: game.server_save("<name>"); server_stop; server_start with that save
--   exec_lua: return remote.call("mb-test", "count")   -- must match; run_ticks; count again
-- Also builds the F7 benchmark saves (docs/feasibility.md F7):
--   exec_lua: return remote.call("mb-test", "bench_hidden", 50)   -- 50 saturated 8:3 networks
--   exec_lua: return remote.call("mb-test", "bench_vanilla", 50)  -- 50 x 24 vanilla splitters
-- Loaded from control.lua only with factorio-test. Results: docs/feasibility.md F6, F7.
local network = require("scripts.network")
local surface = require("scripts.surface")
local builder = require("scripts.builder")
local H = require("tests.game.harness")

local D = defines.direction

local STOCK = 1000

local function build()
  local rig = H.rig({ n = 3, m = 5, stock = STOCK })
  storage.mb_test = rig
  return { built = true, entities = #rig.placed.entities, region = rig.origin }
end

local function count()
  local rig = storage.mb_test
  if not rig then
    error("mb-test: build first")
  end
  local out = { tick = game.tick, sources = 0, visible = 0, network = 0, delivered = 0, outputs = {} }
  for i = 1, rig.n do
    out.sources = out.sources + rig.sources[i][1].get_item_count()
  end
  for _, e in ipairs(rig.visible) do
    out.visible = out.visible + H.items_on(e)
  end
  for _, e in ipairs(rig.feeders) do
    out.visible = out.visible + H.items_on(e)
  end
  for j = 1, rig.m do
    out.visible = out.visible + H.items_on(rig.sink_loaders[j])
    out.outputs[j] = rig.sinks[j].get_item_count()
    out.delivered = out.delivered + out.outputs[j]
  end
  for _, e in ipairs(rig.placed.entities) do
    out.network = out.network + H.items_on(e)
  end
  out.total = out.sources + out.visible + out.network + out.delivered
  out.expected = rig.n * STOCK
  local linked = 0
  for _, e in ipairs(rig.placed.inputs) do
    if e.linked_belt_neighbour and e.linked_belt_neighbour.surface.name == "nauvis" then
      linked = linked + 1
    end
  end
  for _, e in ipairs(rig.placed.outputs) do
    if e.linked_belt_neighbour and e.linked_belt_neighbour.surface.name == "nauvis" then
      linked = linked + 1
    end
  end
  out.linked = linked
  out.hidden_for_player = game.forces.player.get_surface_hidden(rig.placed.inputs[1].surface)
  return out
end

-- Blocks (true) or releases (false) every output.
local function block(on)
  for _, l in ipairs(storage.mb_test.sink_loaders) do
    l.disabled_by_script = on
  end
  return count()
end

-- Benchmark rigs: endless sources (infinity chest, express loader) and sinks (express loader
-- into an infinity chest that removes everything), so they run saturated forever.
local function bench_source(s, x, y)
  local chest = H.ce(s, { name = "infinity-chest", position = { x, y } })
  chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
  H.ce(s, { name = "mb-test-loader-express", position = { x + 1, y }, direction = D.east, type = "output" })
end

local function bench_sink(s, x, y)
  H.ce(s, { name = "mb-test-loader-express", position = { x, y }, direction = D.east, type = "input" })
  local chest = H.ce(s, { name = "infinity-chest", position = { x + 1, y } })
  chest.remove_unfiltered_items = true
end

-- `copies` 8:3 networks on the hidden surface, each with 8 sources and 3 sinks on nauvis.
local function bench_hidden(copies)
  local s = game.surfaces.nauvis
  local entities = 0
  for _ = 1, copies do
    local net = assert(network.build(8, 3))
    local w, h = builder.size(net)
    local placed = builder.place(net, "express", surface.reserve(w, h))
    entities = entities + #placed.entities
    local o = H.area(16, 8 * 2)
    for i = 1, 8 do
      local y = o.y + 2 * (i - 1)
      bench_source(s, o.x, y)
      H.ce(s, { name = "express-transport-belt", position = { o.x + 2, y }, direction = D.east })
      local edge = H.ce(s, { name = "mb-hidden-linked-belt-express", position = { o.x + 3, y }, direction = D.east, type = "input" })
      edge.connect_linked_belts(placed.inputs[i])
    end
    for j = 1, 3 do
      local y = o.y + 2 * (j - 1)
      local edge = H.ce(s, { name = "mb-hidden-linked-belt-express", position = { o.x + 8, y }, direction = D.east, type = "output" })
      edge.connect_linked_belts(placed.outputs[j])
      H.ce(s, { name = "express-transport-belt", position = { o.x + 9, y }, direction = D.east })
      bench_sink(s, o.x + 10, y)
    end
  end
  return { copies = copies, hidden_entities = entities }
end

-- The same number of vanilla express splitters (24 per copy) on nauvis: per copy 8 rows, each
-- an endless source, 3 splitters in series (one input and one output connected; the other
-- output is a dead end that fills and then blocks) with a belt between them, and a sink.
local function bench_vanilla(copies)
  local s = game.surfaces.nauvis
  local splitters = 0
  for _ = 1, copies do
    local o = H.area(16, 8 * 3)
    for i = 1, 8 do
      local y = o.y + 3 * (i - 1)
      bench_source(s, o.x, y)
      local x = o.x + 2
      for _ = 1, 3 do
        H.ce(s, { name = "express-transport-belt", position = { x, y }, direction = D.east })
        H.ce(s, { name = "express-splitter", position = { x + 1, y + 0.5 }, direction = D.east })
        splitters = splitters + 1
        x = x + 2
      end
      H.ce(s, { name = "express-transport-belt", position = { x, y }, direction = D.east })
      bench_sink(s, x + 1, y)
    end
  end
  return { copies = copies, splitters = splitters }
end

remote.add_interface("mb-test", {
  build = build, count = count, block = block, bench_hidden = bench_hidden, bench_vanilla = bench_vanilla,
})
