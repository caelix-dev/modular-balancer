-- Shared rig for the in-game suites and the save/load remote interface (test code only).
--
-- A rig is one network placed on the hidden surface (scripts/builder.lua) plus a visible side on
-- nauvis. Visible side, row k at y = o.y + ROW * (k - 1):
--   input i:  [source chest][loader ->][belt][belt][belt][belt][input linked belt] => placed.inputs[i]
--   output j: placed.outputs[j] => [output linked belt][belt][belt][belt][belt][loader ->][sink chest]
-- Lane feeds put no loader in the input row; instead a feeder column (chest, loader, one belt)
-- side-loads onto the second belt from the north (its left lane) and/or from the south (its right lane).
local network = require("scripts.network")
local builder = require("scripts.builder")
local groups = require("scripts.groups")

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

-- Harness state lives in storage (final review M5), so a save and reload on an MCP instance
-- neither reuses an area nor forgets a rig.
local function state()
  storage.mb_test_harness = storage.mb_test_harness or { next_area = 0, live = {} }
  return storage.mb_test_harness
end

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
  local st = state()
  st.next_area = st.next_area + 1
  local s = game.surfaces.nauvis
  local o = { x = 1000.5, y = st.next_area * 200 + 0.5 }
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

-- Items on a belt-connectable entity's transport lines, or in a container.
function H.items_on(e)
  if e.type == "container" then
    return e.get_item_count()
  end
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
-- opts.n, opts.m: ratio. opts.balance_lanes. opts.tier (default express). opts.recirc: passed to
--   network.build (default on).
-- opts.feed[i]: "full" (default), "slow" (basic-speed loader, a third of express), "lanes"
--   (iron left, copper right), "left" (iron on the left lane only).
-- opts.sink: "full" (default, loader at the tier speed) or "half" (half express speed).
-- opts.sinks[j]: per-output sink loader tier, overriding opts.sink (e.g. "basic").
-- opts.port: number of extra outputs (after the first m) that end in a belt port (F3) with
--   three inserters instead of a belt; default 0.
-- opts.rows: visible rows to make room for (default max(n, m + port)), for a later H.rebuild
--   to more outputs.
-- opts.net: a hand-built network to place instead of network.build(n, m + port).
-- opts.item: item of full / slow feeds (default iron-plate). opts.stock: source stock.
---@param opts {net: table?, n: integer, m: integer, port: integer?, recirc: boolean?, sinks: string[]?, tier: string?, balance_lanes: boolean?, feed: string[]?, sink: string?, item: string?, stock: integer?, rows: integer?}
function H.rig(opts)
  local n, m = opts.n, opts.m
  local ports = opts.port or 0
  local tier = opts.tier or H.TIER
  local belt = BELTS[tier]
  local net = opts.net or assert(network.build(n, m + ports, { balance_lanes = opts.balance_lanes, recirc = opts.recirc }))
  local placed, err = builder.place(net, tier)
  assert(placed, "builder.place failed: " .. tostring(err))
  local s = game.surfaces.nauvis
  local rows = opts.rows or math.max(n, m + ports)
  local o, box = H.area(24, rows * H.ROW)
  local stock = opts.stock or H.SOURCE_STOCK
  local rig = {
    net = net, placed = placed, o = o, box = box, n = n, m = m, tier = tier, opts = opts, stock = stock,
    sources = {}, feeders = {}, sinks = {}, sink_loaders = {}, last_belts = {}, visible = {},
    in_edges = {}, out_edges = {}, port_chests = {}, inserters = {},
  }
  local live = state().live
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
    rig.in_edges[i] = edge
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

  for j = 1, m do
    H.add_output(rig, j)
  end
  local ox = o.x + 12
  for j = m + 1, m + ports do
    -- belt port: an output linked belt under a block, facing west (nothing in front of it),
    -- a dead end; three inserters (north, east, south) take from it into chests
    local y = o.y + H.ROW * (j - 1)
    local k = { x = ox + 2, y = y }
    ce(s, { name = "mb-test-block", position = k })
    local port = ce(s, { name = "mb-hidden-linked-belt-" .. tier, position = k, direction = D.west, type = "output" })
    port.connect_linked_belts(placed.outputs[j])
    rig.visible[#rig.visible + 1] = port
    rig.out_edges[j] = port
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
  return rig
end

-- Visible belt output j: placed.outputs[j] => [output linked belt][4 belts][loader ->][sink chest].
function H.add_output(rig, j)
  local s = game.surfaces.nauvis
  local opts, tier = rig.opts, rig.tier
  local ox, y = rig.o.x + 12, rig.o.y + H.ROW * (j - 1)
  local edge = ce(s, { name = "mb-hidden-linked-belt-" .. tier, position = { ox, y }, direction = D.east, type = "output" })
  edge.connect_linked_belts(rig.placed.outputs[j])
  rig.visible[#rig.visible + 1] = edge
  rig.out_edges[j] = edge
  for x = 1, 4 do
    local b = ce(s, { name = BELTS[tier], position = { ox + x, y }, direction = D.east })
    rig.visible[#rig.visible + 1] = b
    rig.last_belts[j] = b
  end
  rig.sink_loaders[j] = ce(s, {
    name = "mb-test-loader-" .. (opts.sinks and opts.sinks[j] or (opts.sink == "half" and "half" or tier)),
    position = { ox + 5, y }, direction = D.east, type = "input",
  })
  rig.sinks[j] = ce(s, { name = "mb-test-chest", position = { ox + 6, y } })
end

-- Rebuilds the rig's network as n:m (builder.rebuild) and relinks the visible edges. Outputs
-- beyond the new m stay on nauvis, unlinked, with whatever they hold; new outputs get visible
-- rows (make room with opts.rows).
function H.rebuild(rig, m, opts)
  local net = assert(network.build(rig.n, m, opts))
  local placed, err = builder.rebuild(rig.placed, net, rig.tier)
  assert(placed, "builder.rebuild failed: " .. tostring(err))
  rig.net, rig.placed = net, placed
  for i, edge in ipairs(rig.in_edges) do
    edge.connect_linked_belts(placed.inputs[i])
  end
  for j = 1, m do
    if rig.out_edges[j] then
      rig.out_edges[j].connect_linked_belts(placed.outputs[j])
    else
      H.add_output(rig, j)
    end
  end
  rig.m = m
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

-- Items in the rig's hidden network (belts, splitters, loader and buffer chest).
---@return number
function H.network_items(rig)
  local t = 0.0
  for _, it in ipairs(builder.contents(rig.placed)) do
    t = t + it.count
  end
  return t
end

-- Every item the rig holds or delivered: sources, feeders, visible belts, network, sinks, sink
-- loaders, the port, its inserters' hands and chests.
---@return number
function H.total_items(rig)
  local t = 0.0
  for _, list in ipairs(rig.sources) do
    for _, ch in ipairs(list) do
      t = t + ch.get_item_count()
    end
  end
  for _, group in ipairs({ rig.feeders, rig.visible, rig.sink_loaders }) do
    for _, e in ipairs(group) do
      t = t + H.items_on(e)
    end
  end
  t = t + H.network_items(rig)
  for _, ch in ipairs(rig.sinks) do
    t = t + ch.get_item_count()
  end
  if rig.port then
    t = t + H.port_count(rig) - H.items_on(rig.port) -- the port belt is in rig.visible
  end
  return t
end

-- Removes the rig: its network (returning the list builder.destroy returned, which also frees
-- its region) and everything in its nauvis area. Count what is outside the network before
-- calling it. A second call returns an empty list.
function H.teardown(rig)
  if rig.torn then
    return {}
  end
  rig.torn = true
  local items = builder.destroy(rig.placed)
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
  local st = state()
  for _, rig in ipairs(st.live) do
    H.teardown(rig)
  end
  st.live = {}
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

-- Visible balancer blocks (tests/game/groups.lua and the groups save/load check in remote.lua).

-- Builds block `tier` at tile (o.x + dx, o.y + dy) with raise_built, as a player build would
-- reach the mod's events.
function H.block(o, dx, dy, tier, force)
  return ce(game.surfaces.nauvis, {
    name = "mb-balancer-" .. tier, position = { o.x + dx, o.y + dy }, force = force or "player", raise_built = true,
  })
end

-- Recomputes the connected groups of the blocks in `box` from scratch (flood fill over the
-- 4-neighbours with the same name and force) and asserts that scripts/groups.lua agrees: one
-- group per part, holding exactly that part, with the right tier, surface and force. Returns the
-- part sizes, largest first.
function H.check_groups(box, what)
  local s = game.surfaces.nauvis
  local at, list = {}, {}
  for _, e in ipairs(s.find_entities_filtered({ area = box, type = "simple-entity-with-owner" })) do
    if groups.tier_of(e.name) then
      local pos = e.position
      at[math.floor(pos.x --[[@as number]]) .. "," .. math.floor(pos.y --[[@as number]])] = e
      list[#list + 1] = e
    end
  end
  local seen, sizes, ids = {}, {}, {}
  for _, e in ipairs(list) do
    if not seen[e.unit_number] then
      local id = groups.of(e.unit_number)
      assert(id, what .. ": block at " .. serpent.line(e.position) .. " has no group")
      assert(not ids[id], what .. ": two separate parts share group " .. id)
      ids[id] = true
      local g = assert(groups.get(id), what .. ": group " .. id .. " missing")
      assert(g.tier == groups.tier_of(e.name) and g.surface_index == s.index and g.force.index == e.force.index,
        what .. ": group " .. id .. " has the wrong tier, surface or force")
      local queue, n = { e }, 0
      seen[e.unit_number] = true
      while #queue > 0 do
        local b = table.remove(queue)
        n = n + 1
        assert(groups.of(b.unit_number) == id, what .. ": block at " .. serpent.line(b.position) .. " is not in group " .. id)
        local x, y = math.floor(b.position.x), math.floor(b.position.y)
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local nb = at[(x + d[1]) .. "," .. (y + d[2])]
          if nb and not seen[nb.unit_number] and nb.name == e.name and nb.force.index == e.force.index then
            seen[nb.unit_number] = true
            queue[#queue + 1] = nb
          end
        end
      end
      assert(table_size(g.blocks) == n and g.count == n,
        what .. ": group " .. id .. " has " .. table_size(g.blocks) .. " blocks (count " .. g.count .. "), its part " .. n)
      assert(g.force_index == g.force.index, what .. ": group " .. id .. " force_index differs from its force")
      sizes[#sizes + 1] = n
    end
  end
  table.sort(sizes, function(a, b) return a > b end)
  return sizes
end

return H
