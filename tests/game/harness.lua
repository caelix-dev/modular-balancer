-- Shared rig for the in-game suites and the save/load remote interface (test code only).
--
-- A rig is one network placed on the hidden surface (scripts/builder.lua) plus a visible side on
-- nauvis. Visible side, row k at y = o.y + ROW * (k - 1):
--   input i:  [source chest][loader ->][belt][belt][belt][belt][input linked belt] => placed.inputs[i]
--   output j: placed.outputs[j] => [output linked belt][belt][belt][belt][belt][loader ->][sink chest]
-- Lane feeds put no loader in the input row; instead a feeder column (chest, loader, one belt)
-- side-loads onto the second belt from the north (its left lane) and/or from the south (its right lane).
local network = require("scripts.network")
local surface = require("scripts.surface")
local builder = require("scripts.builder")

local H = {}

local D = defines.direction
H.LINES = { defines.transport_line.left_line, defines.transport_line.right_line }
H.TIER = "express"
H.BELT = "express-transport-belt"
H.RATE = 45 -- items per second of a full express belt
H.ROW = 8
H.SOURCE_STOCK = 20000

local BELTS = {
  basic = "transport-belt",
  fast = "fast-transport-belt",
  express = "express-transport-belt",
  turbo = "turbo-transport-belt",
}
H.BELTS = BELTS

local next_area = 0
local live = {} -- rigs built and not torn down yet

local function ce(s, t)
  t.force = t.force or "player"
  local e = s.create_entity(t)
  assert(e, "could not create " .. t.name .. " on " .. s.name .. " at " .. serpent.line(t.position))
  return e
end
H.ce = ce

-- A fresh, cleared, lab-tiled area of nauvis (w x h tiles), far from the others. Returns its
-- top-left tile centre and the cleared box (with an 8-tile margin).
function H.area(w, h)
  next_area = next_area + 1
  local s = game.surfaces.nauvis
  local o = { x = 1000.5, y = next_area * 200 + 0.5 }
  local box = { { o.x - 8, o.y - 8 }, { o.x + w + 8, o.y + h + 8 } }
  s.request_to_generate_chunks({ o.x + w / 2, o.y + h / 2 }, math.ceil(math.max(w, h) / 64) + 1)
  s.force_generate_chunk_requests()
  for _, e in ipairs(s.find_entities_filtered({ area = box })) do
    if e.valid and e.type ~= "character" then
      e.destroy()
    end
  end
  local tiles = {}
  for x = box[1][1], box[2][1] do
    for y = box[1][2], box[2][2] do
      tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } }
    end
  end
  s.set_tiles(tiles)
  return o, box
end

function H.items_on(e)
  local n = 0
  for i = 1, e.get_max_transport_line_index() do
    n = n + e.get_transport_line(i).get_item_count()
  end
  return n
end

local function source_chest(s, p, item, stock)
  local chest = ce(s, { name = "mb-test-chest", position = p })
  if stock > 0 then
    chest.insert({ name = item, count = stock })
  end
  return chest
end

-- Builds a rig.
-- opts.n, opts.m: ratio. opts.balance_lanes. opts.tier (default express).
-- opts.feed[i]: "full" (default), "slow" (basic-speed loader, a third of express), "lanes"
--   (iron left, copper right), "left" (iron on the left lane only).
-- opts.sink: "full" (default, loader at the tier speed) or "half" (half express speed).
-- opts.port: number of extra outputs (after the first m) that end in a belt port (F3) with
--   three inserters instead of a belt; default 0.
-- opts.recirc (F8, experimental, not the product design): equal redistribution. With M = m +
--   port outputs, the network is (n + M):M. Every network output j goes to a hidden splitter
--   with output priority: the priority side is the rig's output j (belt or port), the other
--   side loops back into network input n + j. What an output does not take is spread over all
--   outputs again.
-- opts.sinks[j]: per-output sink loader tier, overriding opts.sink (e.g. "basic").
-- opts.item: item of full / slow feeds (default iron-plate). opts.stock: source stock.
---@param opts {n: integer, m: integer, port: integer?, recirc: boolean?, sinks: string[]?, tier: string?, balance_lanes: boolean?, feed: string[]?, sink: string?, item: string?, stock: integer?}
function H.rig(opts)
  local n, m = opts.n, opts.m
  local ports = opts.port or 0
  local tier = opts.tier or H.TIER
  local belt = BELTS[tier]
  local M = m + ports
  local loops = opts.recirc and M or 0
  local net = assert(network.build(n + loops, M, { balance_lanes = opts.balance_lanes }))
  local w, h = builder.size(net)
  local origin = surface.reserve(w, h)
  local placed = builder.place(net, tier, origin)
  -- what the rig's output j links to
  local targets = {}
  for j = 1, M do
    targets[j] = placed.outputs[j]
  end
  local extra, extra_origin = {}, nil
  if opts.recirc then
    local hs = surface.get()
    local lo = surface.reserve(4, 3 * M)
    extra_origin = lo
    local lb = "mb-hidden-linked-belt-" .. tier
    for j = 1, M do
      local x, y = lo.x, lo.y + 3 * (j - 1)
      local head = ce(hs, { name = lb, position = { x + 0.5, y + 0.5 }, direction = D.east, type = "output" })
      head.connect_linked_belts(placed.outputs[j])
      local sp = ce(hs, { name = "mb-hidden-splitter-" .. tier, position = { x + 1.5, y + 1 }, direction = D.east })
      sp.splitter_output_priority = "left" -- north: the rig's output
      targets[j] = ce(hs, { name = lb, position = { x + 2.5, y + 0.5 }, direction = D.east, type = "input" })
      local back = ce(hs, { name = lb, position = { x + 2.5, y + 1.5 }, direction = D.east, type = "input" })
      back.connect_linked_belts(placed.inputs[n + j])
      for _, e in ipairs({ head, sp, targets[j], back }) do
        extra[#extra + 1] = e
      end
    end
  end
  local s = game.surfaces.nauvis
  local rows = math.max(n, m + ports)
  local o, box = H.area(24, rows * H.ROW)
  local stock = opts.stock or H.SOURCE_STOCK
  local rig = {
    net = net, origin = origin, placed = placed, extra = extra, extra_origin = extra_origin, o = o, box = box,
    n = n, m = m, stock = stock,
    sources = {}, feeders = {}, sinks = {}, sink_loaders = {}, last_belts = {}, visible = {},
    port_chests = {}, inserters = {},
  }
  live[#live + 1] = rig

  for i = 1, n do
    local y = o.y + H.ROW * (i - 1)
    local feed = opts.feed and opts.feed[i] or "full"
    for x = 2, 5 do
      rig.visible[#rig.visible + 1] = ce(s, { name = belt, position = { o.x + x, y }, direction = D.east })
    end
    local edge = ce(s, { name = "mb-hidden-linked-belt-" .. tier, position = { o.x + 6, y }, direction = D.east, type = "input" })
    edge.connect_linked_belts(placed.inputs[i])
    rig.visible[#rig.visible + 1] = edge
    rig.sources[i] = {}
    if feed == "full" or feed == "slow" then
      local item = opts.item or "iron-plate"
      rig.sources[i][1] = source_chest(s, { o.x, y }, item, stock)
      local speed = feed == "slow" and "basic" or tier
      rig.feeders[#rig.feeders + 1] = ce(s, {
        name = "mb-test-loader-" .. speed, position = { o.x + 1, y }, direction = D.east, type = "output",
      })
    else
      -- feeder columns into the belt at x + 3: from the north onto its left lane, from the south
      -- onto its right lane
      ---@type {dir: defines.direction, dy: integer, item: string}[]
      local columns = { { dir = D.south, dy = -1, item = "iron-plate" } }
      if feed == "lanes" then
        columns[2] = { dir = D.north, dy = 1, item = "copper-plate" }
      end
      for _, c in ipairs(columns) do
        local x = o.x + 3
        rig.sources[i][#rig.sources[i] + 1] = source_chest(s, { x, y + 3 * c.dy }, c.item, stock)
        rig.feeders[#rig.feeders + 1] = ce(s, {
          name = "mb-test-loader-" .. tier, position = { x, y + 2 * c.dy }, direction = c.dir, type = "output",
        })
        rig.visible[#rig.visible + 1] = ce(s, { name = belt, position = { x, y + c.dy }, direction = c.dir })
      end
    end
  end

  local ox = o.x + 12
  for j = 1, m + ports do
    local y = o.y + H.ROW * (j - 1)
    if j <= m then
      local edge = ce(s, { name = "mb-hidden-linked-belt-" .. tier, position = { ox, y }, direction = D.east, type = "output" })
      edge.connect_linked_belts(targets[j])
      rig.visible[#rig.visible + 1] = edge
      for x = 1, 4 do
        local b = ce(s, { name = belt, position = { ox + x, y }, direction = D.east })
        rig.visible[#rig.visible + 1] = b
        rig.last_belts[j] = b
      end
      rig.sink_loaders[j] = ce(s, {
        name = "mb-test-loader-" .. (opts.sinks and opts.sinks[j] or (opts.sink == "half" and "half" or tier)),
        position = { ox + 5, y }, direction = D.east, type = "input",
      })
      rig.sinks[j] = ce(s, { name = "mb-test-chest", position = { ox + 6, y } })
    else
      -- belt port: an output linked belt under a block, facing west (nothing in front of it),
      -- a dead end; three inserters (north, east, south) take from it into chests
      local k = { x = ox + 2, y = y }
      ce(s, { name = "mb-test-block", position = k })
      local port = ce(s, { name = "mb-hidden-linked-belt-" .. tier, position = k, direction = D.west, type = "output" })
      port.connect_linked_belts(targets[j])
      rig.visible[#rig.visible + 1] = port
      rig.port = port
      for _, v in ipairs({ { 0, -1, D.south }, { 1, 0, D.west }, { 0, 1, D.north } }) do
        rig.inserters[#rig.inserters + 1] = ce(s, {
          name = "mb-test-inserter", position = { k.x + v[1], k.y + v[2] }, direction = v[3],
        })
        rig.port_chests[#rig.port_chests + 1] = ce(s, {
          name = "mb-test-chest", position = { k.x + 2 * v[1], k.y + 2 * v[2] },
        })
      end
    end
  end
  return rig
end

-- Everything that left the network through the belt port: chests, hands and the port belt.
---@return number
function H.port_count(rig, item)
  local c = 0
  for _, ch in ipairs(rig.port_chests) do
    c = c + (item and ch.get_item_count(item) or ch.get_item_count())
  end
  for _, ins in ipairs(rig.inserters) do
    local h = ins.held_stack
    if h.valid_for_read and (not item or h.name == item) then
      c = c + h.count
    end
  end
  for _, li in ipairs(H.LINES) do
    local line = rig.port.get_transport_line(li)
    c = c + (item and line.get_item_count(item) or line.get_item_count())
  end
  return c
end

-- Items drawn from input i's source chests so far.
---@return number
function H.drawn(rig, i)
  local left = 0
  for _, ch in ipairs(rig.sources[i]) do
    left = left + ch.get_item_count()
  end
  return #rig.sources[i] * rig.stock - left
end

-- Every item the rig holds or delivered: sources, feeders, visible belts, network (and F8
-- recirculation entities), sinks, sink loaders, the port, its inserters' hands and chests.
---@return number
function H.total_items(rig)
  local t = 0.0
  for _, list in ipairs(rig.sources) do
    for _, ch in ipairs(list) do
      t = t + ch.get_item_count()
    end
  end
  for _, group in ipairs({ rig.feeders, rig.visible, rig.placed.entities, rig.extra, rig.sink_loaders }) do
    for _, e in ipairs(group) do
      t = t + H.items_on(e)
    end
  end
  for _, ch in ipairs(rig.sinks) do
    t = t + ch.get_item_count()
  end
  if rig.port then
    t = t + H.port_count(rig) - H.items_on(rig.port) -- the port belt is in rig.visible
  end
  return t
end

-- Removes the rig: its network (returning the list builder.destroy returned), the F8
-- recirculation entities, both hidden regions, and everything in its nauvis area. Count what is
-- outside the network before calling it. A second call returns an empty list.
function H.teardown(rig)
  if rig.torn then
    return {}
  end
  rig.torn = true
  local items = builder.destroy(rig.placed)
  surface.release(rig.origin)
  for _, e in ipairs(rig.extra) do
    if e.valid then
      e.destroy()
    end
  end
  if rig.extra_origin then
    surface.release(rig.extra_origin)
  end
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = rig.box })) do
    if e.valid and e.type ~= "character" then
      e.destroy()
    end
  end
  return items
end

-- Tears down every rig not torn down yet (each suite calls it in after_each, so a test's rig
-- does not keep running through the rest of the suite).
function H.teardown_all()
  for _, rig in ipairs(live) do
    H.teardown(rig)
  end
  live = {}
end

-- Starts a per-tick lane counter on each output's last belt (test only): every tick, it adds the
-- items on each lane to counts[j][lane][item] and clears the lane. Returns the counts table and
-- a function that pauses / resumes it.
function H.lane_counter(rig)
  local counts, paused = {}, false
  for j = 1, rig.m do
    counts[j] = { {}, {} }
  end
  on_tick(function()
    if paused then
      return
    end
    for j, b in ipairs(rig.last_belts) do
      for li = 1, 2 do
        local line = b.get_transport_line(H.LINES[li])
        if line.get_item_count() > 0 then
          for _, st in ipairs(line.get_contents()) do
            counts[j][li][st.name] = (counts[j][li][st.name] or 0) + st.count
          end
          line.clear()
        end
      end
    end
  end)
  return counts, function(p) paused = p end
end

---@param t table<any, number>
---@return number
function H.sum(t)
  local s = 0.0
  for _, v in pairs(t) do
    s = s + v
  end
  return s
end

-- Asserts every value of `list` is within 1 % of their mean.
---@param list number[]
---@param what string
---@return number mean
function H.assert_equal(list, what)
  local mean = 0.0
  for _, v in ipairs(list) do
    mean = mean + v
  end
  mean = mean / #list
  for i, v in ipairs(list) do
    assert(math.abs(v - mean) <= mean * 0.01,
      string.format("%s %d: %.3f is more than 1 %% from the mean %.3f (all: %s)", what, i, v, mean,
        serpent.line(list)))
  end
  return mean
end

-- Waits `warmup` ticks, snapshots `count()` (a list of numbers), waits `window` ticks, and calls
-- back with the per-second rates.
function H.measure(count, warmup, window, callback)
  after_ticks(warmup, function()
    local c0 = count()
    after_ticks(window, function()
      local c1, rates = count(), {}
      for i = 1, #c1 do
        rates[i] = (c1[i] - c0[i]) * 60 / window
      end
      callback(rates)
    end)
  end)
end

function H.report(fmt, ...)
  log("MB-TEST " .. string.format(fmt, ...))
end

return H
