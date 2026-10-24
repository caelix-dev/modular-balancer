-- UPS gate benchmark saves (Plan 3 Task 1, docs/benchmarks.md). Loaded from
-- tests/game/remote.lua, so only with the dev gate `mb-dev`; `bench/` is export-ignored.
--
-- One save = `copies` balancers of one kind, all with the same layout, sources, sinks and belt
-- tier (express). Per copy, K = max(N, M) rows; columns from the copy's left edge:
--   0 infinity chest (source)   1 1x1 express loader   2-3 express belts (east)
--   4-5 two columns of balancer parts, K rows (Better Belt Balancer allows one belt per part
--       on 2.1, so inputs go into the left column and outputs leave the right one; the same
--       2 x K footprint is used for every kind)
--   6-7 express belts (east; with `throttle`, the tile at 7 of output 1 is a basic belt,
--       15 items/s)   8 1x1 express loader   9 infinity chest that deletes everything (sink)
-- Inputs are rows 1..N, outputs rows 1..M. Every visible entity is created with raise_built,
-- as if a player built it, so each mod reacts to it.
--
-- Kinds:
--   mb      modular-balancer blocks mb-balancer-express (recirculating network, the default)
--   bbb     Better Belt Balancer parts bbb-balancer-part
--   bb3     Belt Balancer 3 parts balancer-part
--   plain   no parts: the Plan 1 generator's plain network (network.build with recirc = false)
--           placed by builder.place on the hidden surface, joined to the belts by hidden
--           linked belts on columns 3 and 6 (the "vanilla splitter balancer" reference)
--   none    sources and sinks only, no balancer (inputs and outputs end in the empty columns)
--
-- Remote functions (interface mb-test, see tests/game/remote.lua):
--   bench_build(kind, n, m, copies, throttle)  builds a save's content (a second call builds
--                                              below the first); returns its first copy index
--   bench_counts()                             entities per name on nauvis and hidden surfaces
--                                              (also written to script-output/mb-bench-counts.json)
--   bench_probe_start(i), bench_probe_stop(i)  per-output delivered items of copy i (default 1)
--                                              between the two calls (its sinks keep items
--                                              meanwhile)
--   bench_block(on)                            stops (true) or restarts (false) every sink
--   bench_add_output(first, count)             one more output on copies first..first+count-1
--                                              (a belt leaving the top right block northwards)
--                                              and a timed balancer.flush(); the profiler
--                                              result goes to the log ("mb-bench flush")
local network = require("scripts.network")
local builder = require("scripts.builder")
local balancer = require("scripts.balancer")

local D = defines.direction
local LOADER = "mb-test-loader-express"
local PART = { mb = "mb-balancer-express", bbb = "bbb-balancer-part", bb3 = "balancer-part" }
local COPY_W = 12 -- 10 columns and a 2-tile gap
local ORIGIN = { x = 3000, y = 3000 }
local COLUMN_H = 400 -- copies are stacked in columns at most this tall

---@return { copies: table[], spec: table?, probe_tick: integer?, next_y: number? }
local function bench_state()
  storage.mb_bench = storage.mb_bench or { copies = {} }
  return storage.mb_bench
end

local function ce(s, t, raise)
  t.force = t.force or "player"
  t.raise_built = raise ~= false
  local e = s.create_entity(t)
  assert(e, "bench: could not create " .. t.name .. " at " .. serpent.line(t.position))
  return e
end

-- Generates, clears and lab-tiles the rectangle (tile corners) x1..x2, y1..y2 of nauvis.
local function prepare(s, x1, y1, x2, y2)
  -- Every chunk must be generated before anything is built on it: an entity created on a
  -- chunk that is generated later is wiped by the generation.
  for cx = math.floor(x1 / 32), math.floor(x2 / 32) do
    for cy = math.floor(y1 / 32), math.floor(y2 / 32) do
      s.request_to_generate_chunks({ cx * 32 + 16, cy * 32 + 16 }, 1)
    end
  end
  s.force_generate_chunk_requests()
  for cx = math.floor(x1 / 32), math.floor(x2 / 32) do
    for cy = math.floor(y1 / 32), math.floor(y2 / 32) do
      if not s.is_chunk_generated({ cx, cy }) then
        error("bench: chunk " .. cx .. "," .. cy .. " was not generated")
      end
    end
  end
  for _, e in ipairs(s.find_entities_filtered({ area = { { x1, y1 }, { x2, y2 } } })) do
    if e.valid and e.type ~= "character" then
      e.destroy()
    end
  end
  local tiles = {}
  for x = x1, x2 - 1 do
    for y = y1, y2 - 1 do
      tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } }
    end
  end
  s.set_tiles(tiles)
end

local function source(s, x, y)
  local chest = ce(s, { name = "infinity-chest", position = { x, y } })
  chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
  ce(s, { name = LOADER, position = { x + 1, y }, direction = D.east, type = "output" })
  return chest
end

local function sink(s, x, y)
  local loader = ce(s, { name = LOADER, position = { x, y }, direction = D.east, type = "input" })
  local chest = ce(s, { name = "infinity-chest", position = { x + 1, y } })
  chest.remove_unfiltered_items = true
  return loader, chest
end

local function build_copy(s, kind, n, m, ox, oy, throttle)
  local k = math.max(n, m)
  local copy = { kind = kind, n = n, m = m, x = ox, y = oy, sinks = {}, sink_loaders = {} }
  ---@type table
  local placed = {}
  if kind == "plain" then
    local net = network.build(n, m, { recirc = false }) --[[@as mb.Network]]
    local p = builder.place(net, "express") --[[@as table?]]
    if not p then
      error("bench: could not place the plain network")
    end
    placed = p
  end
  for i = 1, n do
    local y = oy + i - 1 + 0.5
    source(s, ox + 0.5, y)
    ce(s, { name = "express-transport-belt", position = { ox + 2.5, y }, direction = D.east })
    if kind == "plain" then
      local edge = ce(s, { name = "mb-hidden-linked-belt-express", position = { ox + 3.5, y }, direction = D.east, type = "input" }, false)
      edge.connect_linked_belts(placed.inputs[i])
    else
      ce(s, { name = "express-transport-belt", position = { ox + 3.5, y }, direction = D.east })
    end
  end
  local part = PART[kind] --[[@as string?]]
  if part then
    for r = 1, k do
      for dx = 4, 5 do
        ce(s, { name = part, position = { ox + dx + 0.5, oy + r - 1 + 0.5 } })
      end
    end
  end
  for j = 1, m do
    local y = oy + j - 1 + 0.5
    if kind == "plain" then
      local edge = ce(s, { name = "mb-hidden-linked-belt-express", position = { ox + 6.5, y }, direction = D.east, type = "output" }, false)
      edge.connect_linked_belts(placed.outputs[j])
    else
      ce(s, { name = "express-transport-belt", position = { ox + 6.5, y }, direction = D.east })
    end
    local slow = throttle and j == 1
    ce(s, { name = slow and "transport-belt" or "express-transport-belt", position = { ox + 7.5, y }, direction = D.east })
    copy.sink_loaders[j], copy.sinks[j] = sink(s, ox + 8.5, y)
  end
  return copy, placed.entities and #placed.entities or 0
end

local function bench_counts()
  local out = {}
  for _, s in pairs(game.surfaces) do
    local by = {}
    local total = 0
    for _, e in ipairs(s.find_entities_filtered({})) do
      if e.type ~= "resource" and e.type ~= "tree" and e.type ~= "simple-entity" and e.type ~= "fish"
        and e.type ~= "cliff" and e.type ~= "character" then
        by[e.name] = (by[e.name] or 0) + 1
        total = total + 1
      end
    end
    if total > 0 then
      out[s.name] = { total = total, by_name = by }
    end
  end
  helpers.write_file("mb-bench-counts.json", helpers.table_to_json(out))
  return out
end

local function bench_build(kind, n, m, copies, throttle)
  if not (kind == "none" or kind == "plain" or PART[kind]) then
    error("bench: unknown kind " .. tostring(kind))
  end
  local s = game.surfaces.nauvis
  local k = math.max(n, m)
  local row_h = k + 2
  local per_col = math.max(1, math.floor(COLUMN_H / row_h))
  local cols = math.ceil(copies / per_col)
  local st = bench_state()
  local y0 = st.next_y or ORIGIN.y
  local y1 = y0 + math.min(copies, per_col) * row_h
  prepare(s, ORIGIN.x - 4, y0 - 4, ORIGIN.x + cols * COPY_W + 4, y1 + 4)
  -- No enemies anywhere on nauvis (worms near the build area destroy it, and units would cost
  -- update time that differs between saves), and none to come.
  for _, e in ipairs(s.find_entities_filtered({ force = "enemy" })) do
    e.destroy()
  end
  s.peaceful_mode = true
  game.map_settings.enemy_expansion.enabled = false
  game.map_settings.pollution.enabled = false
  local first = #st.copies + 1
  local hidden = 0
  for c = 1, copies do
    local col, row = math.floor((c - 1) / per_col), (c - 1) % per_col
    local copy, h = build_copy(s, kind, n, m, ORIGIN.x + col * COPY_W, y0 + row * row_h, throttle)
    st.copies[#st.copies + 1] = copy
    hidden = hidden + h
  end
  st.next_y = y1 + 16
  st.spec = { kind = kind, n = n, m = m, copies = copies, throttle = throttle and true or false }
  return { spec = st.spec, first_copy = first, plain_hidden_entities = hidden }
end

local function bench_probe_start(index)
  local copy = bench_state().copies[index or 1] --[[@as table]]
  for _, chest in ipairs(copy.sinks) do
    chest.remove_unfiltered_items = false
    chest.clear_items_inside()
  end
  bench_state().probe_tick = game.tick
  return game.tick
end

local function bench_probe_stop(index)
  local st = bench_state()
  local copy = st.copies[index or 1] --[[@as table]]
  local out = { ticks = game.tick - (st.probe_tick or game.tick), per_output = {}, total = 0 }
  for j, chest in ipairs(copy.sinks) do
    local c = chest.get_item_count("iron-plate")
    out.per_output[j] = c
    out.total = out.total + c
    chest.clear_items_inside()
    chest.remove_unfiltered_items = true
  end
  out.per_second = out.total * 60 / math.max(1, out.ticks)
  return out
end

local function bench_block(on)
  for _, copy in ipairs(bench_state().copies) do
    for _, l in ipairs(copy.sink_loaders) do
      l.disabled_by_script = on
    end
  end
  return true
end

local function bench_add_output(first, count)
  local s = game.surfaces.nauvis
  local copies = bench_state().copies
  for c = first, first + count - 1 do
    local copy = copies[c]
    if not copy or copy.extra then
      error("bench: no copy " .. c .. ", or it already has its extra output")
    end
    copy.extra = true
    -- a belt leaving the top right block northwards
    ce(s, { name = "express-transport-belt", position = { copy.x + 5.5, copy.y - 0.5 }, direction = D.north })
  end
  local p = helpers.create_profiler()
  balancer.flush()
  p.stop()
  log({ "", "mb-bench flush first=" .. first .. " count=" .. count .. ": ", p })
  return true
end

return {
  bench_build = bench_build,
  bench_counts = bench_counts,
  bench_probe_start = bench_probe_start,
  bench_probe_stop = bench_probe_stop,
  bench_block = bench_block,
  bench_add_output = bench_add_output,
}
