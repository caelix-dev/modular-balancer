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
-- UPS gate saves against Better Belt Balancer and Belt Balancer 3 (Plan 3 Task 1): the bench_*
-- functions of bench/builders.lua, results in docs/benchmarks.md.
-- Groups save/load check (save_load_keeps_groups, Plan 2 Task 3):
--   exec_lua: return remote.call("mb-test", "groups_build")    -- blocks in several groups
--   exec_lua: return remote.call("mb-test", "groups_summary")  -- before the save
--   save, server_stop, server_start with the save; groups_summary must match
--   exec_lua: return remote.call("mb-test", "groups_bridge")   -- a block built after the load
--                                                                 merges two groups
--   exec_lua: remote.call("mb-test", "groups_destroy"); run_ticks 2; groups_summary
--                                       -- a block destroyed without an event after the load
--                                          leaves its group (on_object_destroyed)
-- Loaded from control.lua only with the dev gate `mb-dev` (settings.lua: factorio-test and the
-- dev marker tests/dev.lua, which release zips leave out). Results: docs/feasibility.md F6, F7.
local network = require("scripts.network")
local builder = require("scripts.builder")
local H = require("tests.game.harness")
local gui = require("scripts.gui")
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")
local lifecycle = require("scripts.lifecycle")

local D = defines.direction

local STOCK = 1000

local function build()
  local rig = H.rig({ n = 3, m = 5, stock = STOCK })
  storage.mb_test = rig
  return { built = true, entities = #rig.placed.entities, region = rig.placed.origin }
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
    local placed = assert(H.place(net, "express"))
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

-- An L with a branch of 9 fast blocks, basic rows of 3 and 2 with a one-tile gap, and an
-- express pair.
local function groups_build()
  local o, box = H.area(12, 12)
  storage.mb_test_groups = { o = o, box = box }
  for _, p in ipairs({ { 2, 2 }, { 2, 3 }, { 2, 4 }, { 2, 5 }, { 3, 5 }, { 4, 5 }, { 5, 5 }, { 1, 3 }, { 0, 3 } }) do
    H.block(o, p[1], p[2], "fast")
  end
  for _, dx in ipairs({ 0, 1, 2, 4, 5 }) do
    H.block(o, dx, 8, "basic")
  end
  H.block(o, 8, 0, "express")
  H.block(o, 8, 1, "express")
  return true
end

local function groups_summary()
  local t = storage.mb_test_groups
  if not t then
    error("mb-test: groups_build first")
  end
  local list = {}
  for id, g in pairs(storage.groups.by_id) do
    list[#list + 1] = { id = id, tier = g.tier, blocks = table_size(g.blocks) }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return { tick = game.tick, parts = H.check_groups(t.box, "summary"), groups = list, next_id = storage.groups.next_id }
end

-- Fills the gap of the basic rows: the 3 and the 2 merge into one group of 6.
local function groups_bridge()
  H.block(storage.mb_test_groups.o, 3, 8, "basic")
  return groups_summary()
end

-- Destroys one block of the express pair without an event.
local function groups_destroy()
  local o = storage.mb_test_groups.o
  local e = game.surfaces.nauvis.find_entities_filtered({ position = { o.x + 8, o.y + 1 }, name = "mb-balancer-express" })[1]
  return e ~= nil and e.destroy()
end

-- Opens the settings GUI (scripts/gui.lua) of the block at (x, y) for a player, as clicking it
-- would (Plan 3 Task 3 screenshot; a GUI client cannot click from the MCP tools):
--   exec_lua: return remote.call("mb-test", "gui_open", 1, x, y)
local function gui_open(player_index, x, y)
  local player = game.get_player(player_index)
  local e = player and player.surface.find_entities_filtered({ position = { x, y }, type = "simple-entity-with-owner", limit = 1 })[1]
  if not (player and e) then
    return false
  end
  gui.open(player, e)
  return player.gui.screen.mb_settings ~= nil
end

-- Real-player checks (Plan 3 Task 5, docs/feasibility.md F11). A GUI client cannot press keys or
-- click from the MCP tools, so these call the mod's handlers with the event a real key press or
-- click raises, for the connected player (its real selection, cursor, reach, controller and
-- permission group):
--   input(name, player_index)    name = "open" | "copy" | "paste": the linked custom inputs
--   click(player_index, what)    what = "lanes" | "recirc" (toggles the checkbox, then raises
--                                what the click raises) | "close" (the close button)
--   setup_blueprint(player_index) on_player_setup_blueprint for the blueprint in the cursor, as
--                                Ctrl+C / a blueprint selection raises it (mapping from
--                                create_blueprint over `area`)
--   info(x, y)                   the group of the block at (x, y): settings and network
--   gui_info(player_index)       the frame, player.opened and storage.mb_gui for the player
local function block_at(s, x, y)
  return s.find_entities_filtered({ position = { x, y }, type = "simple-entity-with-owner", limit = 1 })[1]
end

local function input(name, player_index)
  local ev = { player_index = player_index, input_name = "mb-" .. name, tick = game.tick } --[[@as any]]
  if name == "open" then
    gui.on_open_input(ev)
  elseif name == "copy" then
    gui.on_copy_input(ev)
  elseif name == "paste" then
    gui.on_paste_input(ev)
  else
    error("mb-test input: " .. tostring(name))
  end
  return true
end

local function click(player_index, what)
  local player = assert(game.get_player(player_index))
  local frame = player.gui.screen.mb_settings
  if not frame then
    return "no frame"
  end
  if what == "close" then
    local ev = { player_index = player_index, element = frame.mb_titlebar.mb_close } --[[@as any]]
    gui.on_click(ev)
  else
    local el = frame.mb_inner["mb_" .. what]
    el.state = not el.state
    local ev = { player_index = player_index, element = el } --[[@as any]]
    gui.on_checked(ev)
  end
  return true
end

local function setup_blueprint(player_index, area)
  local player = assert(game.get_player(player_index))
  local st = player.cursor_stack
  if not (st and st.valid_for_read and st.is_blueprint) then
    return "no blueprint in the cursor"
  end
  local map = st.create_blueprint({ surface = player.surface, force = player.force, area = area })
  lifecycle.on_player_setup_blueprint({ player_index = player_index, stack = st,
    mapping = { valid = true, get = function() return map end } })
  local names = {}
  for _, be in ipairs(st.get_blueprint_entities() or {}) do
    names[#names + 1] = be.name .. (be.tags and (" " .. serpent.line(be.tags)) or "")
  end
  return names
end

local function info(x, y)
  local e = block_at(game.surfaces.nauvis, x, y)
  local id = e and groups.of(e.unit_number)
  if not id then
    return { block = e ~= nil, group = false }
  end
  local s = groups.settings(id)
  local rec = balancer.get(id)
  local refused = {}
  for _, r in ipairs(rec and rec.refused or {}) do
    refused[#refused + 1] = r.reason
  end
  return { group = id, lanes = s.lanes, recirc = s.recirc, n = rec and rec.n, m = rec and rec.m,
    placed = rec ~= nil and rec.placed ~= nil, net_lanes = rec and rec.lanes, net_recirc = rec and rec.recirc,
    refused = refused }
end

local function gui_info(player_index)
  local player = assert(game.get_player(player_index))
  local frame = player.gui.screen.mb_settings --[[@as LuaGuiElement?]]
  local st = storage.mb_gui or { open = {}, copy = {} }
  local open, copy = st.open[player_index], st.copy[player_index]
  local out = { frame = frame ~= nil, opened = player.opened and player.opened.object_name or "nil",
    open = open and (open.valid and open.unit_number or "invalid") or "nil",
    copy = copy and (copy.valid and copy.unit_number or "invalid") or "nil" }
  if frame then
    out.ratio = frame.mb_inner.mb_ratio.caption
    out.lanes = frame.mb_inner.mb_lanes.state
    out.recirc = frame.mb_inner.mb_recirc.state
    out.opened_is_frame = player.opened == frame
  end
  return out
end

local functions = {
  gui_open = gui_open, input = input, click = click, setup_blueprint = setup_blueprint, info = info,
  gui_info = gui_info,
  build = build, count = count, block = block, bench_hidden = bench_hidden, bench_vanilla = bench_vanilla,
  groups_build = groups_build, groups_summary = groups_summary, groups_bridge = groups_bridge,
  groups_destroy = groups_destroy,
}
-- UPS gate saves (Plan 3 Task 1): bench/builders.lua, docs/benchmarks.md.
for name, fn in pairs(require("bench.builders")) do
  functions[name] = fn
end
remote.add_interface("mb-test", functions)
