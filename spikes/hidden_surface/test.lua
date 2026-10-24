-- Spike S2 (throwaway): linked belts across surfaces (F2), inserter access to a hidden
-- network (F3), inserters putting items in (F4), lane balancing (F5). Runs only with the
-- `mb-spikes` setting. Results are logged with the prefix "MB-SPIKE" (factorio-current.log)
-- and recorded in docs/feasibility.md F2-F5. The save/load half of F2 runs on an MCP server
-- instance (see docs/feasibility.md), not here.

local D = defines.direction
local SA = script.active_mods["space-age"] ~= nil
local BELT = SA and "turbo-transport-belt" or "express-transport-belt"
local SPLITTER = SA and "turbo-splitter" or "express-splitter"
local RATE = SA and 60 or 45 -- items per second of one full belt of the measured tier
local MEASURE = 3600
local WARMUP = 600

local VEC = {
  [D.north] = { 0, -1 },
  [D.east] = { 1, 0 },
  [D.south] = { 0, 1 },
  [D.west] = { -1, 0 },
}
local LINES = { defines.transport_line.left_line, defines.transport_line.right_line }
local OPPOSITE = { [D.north] = D.south, [D.east] = D.west, [D.south] = D.north, [D.west] = D.east }

local visible ---@type LuaSurface  nauvis, the player's surface
local hidden ---@type LuaSurface   the hidden network surface
local next_row = 0

local function report(fmt, ...)
  log("MB-SPIKE " .. string.format(fmt, ...))
end

local function ce(s, t)
  t.force = t.force or "player"
  local e = s.create_entity(t)
  assert(e, "could not create " .. t.name .. " on " .. s.name .. " at " .. serpent.line(t.position))
  return e
end

-- A fresh 40-tile row per test, far from the others; the same position on both surfaces.
local function origin()
  next_row = next_row + 1
  return { x = 0.5, y = next_row * 40 + 0.5 }
end

local function at(o, dx, dy)
  return { x = o.x + dx, y = o.y + dy }
end

local function step(o, dir, n)
  local v = VEC[dir]
  return at(o, v[1] * n, v[2] * n)
end

local function items_on(e)
  return e.get_transport_line(LINES[1]).get_item_count() + e.get_transport_line(LINES[2]).get_item_count()
end

-- `len` belts from `p` in direction `dir`; returns the position after the last one.
local function belts(s, p, dir, len)
  for i = 0, len - 1 do
    ce(s, { name = BELT, position = step(p, dir, i), direction = dir })
  end
  return step(p, dir, len)
end

-- Saturated source: infinity chest at `p`, loader one tile further in `dir` putting items on
-- a belt that starts after it. Returns the position of the first belt tile.
local function source(s, p, dir, item)
  local chest = ce(s, { name = "infinity-chest", position = p })
  chest.set_infinity_container_filter(1, { name = item or "iron-plate", count = 100, mode = "exactly" })
  ce(s, { name = "mb-spike-io-loader", position = step(p, dir, 1), direction = dir, type = "output" })
  return step(p, dir, 2)
end

-- Counting sink: a loader at `p` (belt arriving in direction `dir`) into a large chest.
local function sink(s, p, dir)
  ce(s, { name = "mb-spike-io-loader", position = p, direction = dir, type = "input" })
  return ce(s, { name = "mb-spike-sink", position = step(p, dir, 1) })
end

-- Waits `warmup` ticks, then counts `count()` (a list of numbers) over MEASURE ticks and
-- calls back with the per-second rates. Ends the test unless the callback returns true.
local function measure(count, callback, warmup)
  local c0
  after_ticks(warmup or WARMUP, function()
    c0 = count()
    after_ticks(MEASURE, function()
      local c1, rates = count(), {}
      for i = 1, #c1 do rates[i] = (c1[i] - c0[i]) * 60 / MEASURE end
      if not callback(rates) then done() end
    end)
  end)
end

local function chest_counts(chests)
  return function()
    local c = {}
    for i, ch in ipairs(chests) do c[i] = ch.get_item_count() end
    return c
  end
end

-- Clears a 40x40 area of `s` around `o` and lays lab tiles (nauvis has water, trees, cliffs).
local function prepare(s, o)
  local area = { { o.x - 20, o.y - 20 }, { o.x + 20, o.y + 20 } }
  for _, e in ipairs(s.find_entities_filtered({ area = area })) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = o.x - 20, o.x + 19 do
    for y = o.y - 20, o.y + 19 do
      tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } }
    end
  end
  s.set_tiles(tiles)
end

local function region()
  local o = origin()
  prepare(visible, o)
  return o
end

describe("spike S2: hidden surface", function()
  before_all(function()
    visible = game.surfaces.nauvis
    visible.request_to_generate_chunks({ 0, 400 }, 14)
    visible.force_generate_chunk_requests()
    hidden = game.create_surface("mb-spike-hidden", { width = 128, height = 1000 })
    hidden.generate_with_lab_tiles = true
    hidden.request_to_generate_chunks({ 0, 400 }, 14)
    hidden.force_generate_chunk_requests()
    game.forces.player.set_surface_hidden(hidden, true)
    game.forces.player.bulk_inserter_capacity_bonus = 11
    report("S2 tier belt %s, full belt %d items/s; hidden surface hidden for player: %s",
      BELT, RATE, tostring(game.forces.player.get_surface_hidden(hidden)))
  end)

  after_all(function()
    game.delete_surface(hidden)
  end)

  -- F2: the same chain, once through the hidden surface and once on nauvis only:
  --   source -> 3 belts -> input linked belt => output linked belt -> 6 belts
  --   -> input linked belt => output linked belt -> 3 belts -> sink.
  test("linked_belt_cross_surface_throughput", function()
    async(WARMUP + MEASURE + 300)
    local o = region()
    local function chain(row, mid_surface, mid_row)
      local p = belts(visible, source(visible, at(o, -8, row), D.east), D.east, 3)
      local in1 = ce(visible, { name = "mb-spike-lb", position = p, direction = D.east, type = "input" })
      local q = at(o, 0, mid_row)
      local out1 = ce(mid_surface, { name = "mb-spike-lb", position = q, direction = D.east, type = "output" })
      q = belts(mid_surface, step(q, D.east, 1), D.east, 6)
      local in2 = ce(mid_surface, { name = "mb-spike-lb", position = q, direction = D.east, type = "input" })
      local r = at(o, 0, row)
      local out2 = ce(visible, { name = "mb-spike-lb", position = r, direction = D.east, type = "output" })
      in1.connect_linked_belts(out1)
      in2.connect_linked_belts(out2)
      assert(in1.linked_belt_neighbour == out1 and out2.linked_belt_neighbour == in2, "link refused")
      return sink(visible, belts(visible, step(r, D.east, 1), D.east, 3), D.east)
    end
    local across = chain(0, hidden, 0)
    local same = chain(4, visible, 8)
    measure(chest_counts({ across, same }), function(rates)
      report("F2 throughput over %d ticks: across surfaces %.3f, one surface %.3f items/s (full belt %d)",
        MEASURE, rates[1], rates[2], RATE)
      assert(math.abs(rates[1] - rates[2]) <= rates[2] * 0.01, "cross-surface throughput differs by more than 1 %")
      assert(rates[2] >= RATE * 0.99, "one-surface chain below a full belt")
    end)
  end)

  -- F3: an inserter takes from a proxy container on nauvis whose target is a chest on the
  -- hidden surface.
  test("inserter_takes_from_proxy_of_hidden_chest", function()
    async(600)
    local o = region()
    local chest = ce(hidden, { name = "steel-chest", position = o })
    chest.insert({ name = "iron-plate", count = 100 })
    local proxy = ce(visible, { name = "proxy-container", position = o })
    proxy.proxy_target_entity = chest
    proxy.proxy_target_inventory = defines.inventory.chest
    local ins = ce(visible, { name = "mb-spike-inserter", position = at(o, 1, 0), direction = D.west })
    local out = ce(visible, { name = "steel-chest", position = at(o, 2, 0) })
    report("F3 proxy target on %s; proxy shows %d items; inserter pickup_target %s",
      proxy.proxy_target_entity.surface.name, proxy.get_item_count(),
      ins.pickup_target and ins.pickup_target.name or "nil")
    after_ticks(300, function()
      local moved, left = out.get_item_count(), chest.get_item_count()
      report("F3 after 300 ticks: %d moved to the nauvis chest, %d left in the hidden chest", moved, left)
      assert(moved > 0, "the inserter took nothing through the proxy")
      assert(moved + left == 100, "items lost or duplicated: " .. (moved + left))
      done()
    end)
  end)

  -- F3 exactness: a splitter on the hidden surface with output A to a belt sink and output B
  -- through a loader into a one-slot buffer chest, which a proxy on nauvis exposes to three
  -- inserters. The inserters are one more output: with room they get exactly half, and when
  -- they stop the whole flow goes to A.
  test("inserter_share_is_exact", function()
    async(WARMUP * 2 + MEASURE * 2 + 600)
    local o = region()
    local p = belts(hidden, source(hidden, at(o, -8, 0), D.east), D.east, 3)
    ce(hidden, { name = SPLITTER, position = { x = p.x, y = p.y + 0.5 }, direction = D.east })
    local a = sink(hidden, belts(hidden, step(p, D.east, 1), D.east, 3), D.east)
    local lp = belts(hidden, at(p, 1, 1), D.east, 3)
    ce(hidden, { name = "mb-spike-io-loader", position = lp, direction = D.east, type = "input" })
    local buffer = ce(hidden, { name = "mb-spike-buffer", position = step(lp, D.east, 1) })
    local block = step(lp, D.east, 1)
    local proxy = ce(visible, { name = "mb-spike-proxy", position = block })
    proxy.proxy_target_entity = buffer
    proxy.proxy_target_inventory = defines.inventory.chest
    local inserters, outs = {}, {}
    for _, dir in ipairs({ D.north, D.east, D.south }) do
      -- an inserter's direction points at its pickup side (the proxy)
      inserters[#inserters + 1] = ce(visible, {
        name = "mb-spike-inserter", position = step(block, dir, 1), direction = OPPOSITE[dir],
      })
      outs[#outs + 1] = ce(visible, { name = "steel-chest", position = step(block, dir, 2) })
    end
    -- pickup_target is nil until the inserter's first update
    after_ticks(5, function()
      for _, ins in ipairs(inserters) do
        assert(ins.pickup_target == proxy, "inserter does not pick up from the proxy")
      end
    end)
    local function counts()
      local b = buffer.get_item_count()
      for _, ch in ipairs(outs) do b = b + ch.get_item_count() end
      return { a.get_item_count(), b }
    end
    measure(counts, function(free)
      report("F3 share, inserters free: belt output %.3f, inserter output %.3f items/s (half belt %.1f)",
        free[1], free[2], RATE / 2)
      assert(math.abs(free[1] - RATE / 2) <= RATE / 2 * 0.01, "belt output is not half")
      assert(math.abs(free[2] - RATE / 2) <= RATE / 2 * 0.01, "inserter output is not half")
      for _, ins in ipairs(inserters) do ins.disabled_by_script = true end
      measure(counts, function(stopped)
        report("F3 share, inserters stopped: belt output %.3f, inserter output %.3f items/s; buffer holds %d",
          stopped[1], stopped[2], buffer.get_item_count())
        assert(stopped[1] >= RATE * 0.99, "the stopped inserters' share did not go to the belt output")
        assert(stopped[2] == 0, "items reached the stopped inserters' output")
      end)
      return true
    end)
  end)

  -- F3: the proxy as the visible block shares its tile with one hidden linked belt (the F1
  -- block-tile interface). Which entity does an inserter pointed at that tile pick from?
  test("proxy_block_shares_tile_with_linked_belt", function()
    async(600)
    local o = region()
    local chest = ce(hidden, { name = "steel-chest", position = o })
    chest.insert({ name = "iron-plate", count = 100 })
    local lb = ce(visible, { name = "mb-spike-lb", position = o, direction = D.north, type = "output" })
    local proxy = ce(visible, { name = "mb-spike-proxy", position = o })
    proxy.proxy_target_entity = chest
    proxy.proxy_target_inventory = defines.inventory.chest
    lb.get_transport_line(LINES[1]).insert_at(0.25, { name = "copper-plate", count = 1 })
    local ins = ce(visible, { name = "mb-spike-inserter", position = at(o, 1, 0), direction = D.west })
    local out = ce(visible, { name = "steel-chest", position = at(o, 2, 0) })
    local at_build = ins.pickup_target and ins.pickup_target.name or "nil"
    after_ticks(60, function()
      report("F3 tile with proxy + linked belt: pickup_target at build %s, after 60 ticks %s; taken so far: %d iron (proxy), %d copper (belt)",
        at_build, ins.pickup_target and ins.pickup_target.name or "nil",
        out.get_item_count("iron-plate"), out.get_item_count("copper-plate"))
      ins.pickup_target = proxy
      report("F3 tile with proxy + linked belt: pickup_target after writing %s",
        ins.pickup_target and ins.pickup_target.name or "nil")
    end)
    after_ticks(360, function()
      report("F3 tile with proxy + linked belt: %d iron (proxy) and %d copper (belt) taken",
        out.get_item_count("iron-plate"), out.get_item_count("copper-plate"))
      assert(ins.pickup_target == proxy, "pickup_target did not stay on the proxy")
      assert(out.get_item_count("iron-plate") > 0, "nothing taken from the proxy")
      done()
    end)
  end)

  -- F4: an inserter puts items into a proxy whose target is a hidden chest drained by a
  -- loader onto a belt (the stand-in for a network input). A finite chest of 200 plates
  -- must arrive in full.
  test("inserter_puts_into_proxy", function()
    async(3000)
    local o = region()
    local buffer = ce(hidden, { name = "mb-spike-buffer", position = o })
    ce(hidden, { name = "mb-spike-io-loader", position = at(o, 1, 0), direction = D.east, type = "output" })
    local s = sink(hidden, belts(hidden, at(o, 2, 0), D.east, 4), D.east)
    local proxy = ce(visible, { name = "mb-spike-proxy", position = o })
    proxy.proxy_target_entity = buffer
    proxy.proxy_target_inventory = defines.inventory.chest
    local from = ce(visible, { name = "steel-chest", position = at(o, -2, 0) })
    from.insert({ name = "iron-plate", count = 200 })
    local ins = ce(visible, { name = "mb-spike-inserter", position = at(o, -1, 0), direction = D.west })
    after_ticks(5, function()
      report("F4 inserter drop_target after 5 ticks: %s", ins.drop_target and ins.drop_target.name or "nil")
      assert(ins.drop_target == proxy, "inserter does not drop into the proxy")
    end)
    after_ticks(2400, function()
      report("F4 after 2400 ticks: %d of 200 reached the network-side sink; %d left in the source, %d in the buffer",
        s.get_item_count(), from.get_item_count(), buffer.get_item_count())
      assert(s.get_item_count() == 200, "not all 200 items reached the network side")
      done()
    end)
  end)

  -- F4: one proxy for both directions. An inserter dropping into the output buffer's proxy
  -- puts items straight into the buffer, where the taking inserter takes them: they never
  -- pass the network.
  test("put_and_take_on_one_proxy_bypass_the_network", function()
    async(1500)
    local o = region()
    local buffer = ce(hidden, { name = "mb-spike-buffer", position = o })
    local proxy = ce(visible, { name = "mb-spike-proxy", position = o })
    proxy.proxy_target_entity = buffer
    proxy.proxy_target_inventory = defines.inventory.chest
    local from = ce(visible, { name = "steel-chest", position = at(o, -2, 0) })
    from.insert({ name = "copper-plate", count = 100 })
    ce(visible, { name = "mb-spike-inserter", position = at(o, -1, 0), direction = D.west })
    ce(visible, { name = "mb-spike-inserter", position = at(o, 1, 0), direction = D.west })
    local out = ce(visible, { name = "steel-chest", position = at(o, 2, 0) })
    after_ticks(1200, function()
      report("F4 put and take on one proxy: %d of 100 went straight from the putting to the taking inserter",
        out.get_item_count("copper-plate"))
      assert(out.get_item_count("copper-plate") > 0, "expected items to bypass the network")
      done()
    end)
  end)

  -- F5: 1:2 with only the right lane of the input fed (side-loaded from the south). Each output's two lanes
  -- are counted on its last belt tile, which is emptied every tick (test harness only).
  -- Constructions: splitter only (control), lane splitter before the splitter, splitter with
  -- a lane splitter on each output.
  test("lane_mode_balances_lanes", function()
    async(WARMUP + MEASURE + 300)
    local o = region()
    local ends = {}
    local function build(row, before, after)
      local b = at(o, 0, row)
      -- side feed: a belt from the south pointing into the side of the input tile at x-6,
      -- which has an (empty) belt behind it so it stays straight; the south side of an east
      -- belt is its right lane.
      local f = belts(hidden, source(hidden, at(b, -6, 6), D.north), D.north, 4)
      assert(f.y == b.y and f.x == b.x - 6, "side feed misplaced")
      ce(hidden, { name = BELT, position = at(b, -7, 0), direction = D.east })
      local p = at(b, -6, 0)
      ce(hidden, { name = BELT, position = p, direction = D.east })
      p = step(p, D.east, 1)
      if before then
        ce(hidden, { name = "mb-spike-lane-splitter", position = p, direction = D.east })
      else
        ce(hidden, { name = BELT, position = p, direction = D.east })
      end
      p = belts(hidden, step(p, D.east, 1), D.east, 2)
      ce(hidden, { name = SPLITTER, position = { x = p.x, y = p.y + 0.5 }, direction = D.east })
      local list = {}
      for k = 0, 1 do
        local q = at(p, 1, k)
        q = belts(hidden, q, D.east, 1)
        if after then
          ce(hidden, { name = "mb-spike-lane-splitter", position = q, direction = D.east })
        else
          ce(hidden, { name = BELT, position = q, direction = D.east })
        end
        q = belts(hidden, step(q, D.east, 1), D.east, 2)
        list[#list + 1] = ce(hidden, { name = BELT, position = q, direction = D.east })
      end
      ends[#ends + 1] = list
    end
    build(0, false, false)
    build(10, true, false)
    build(20, false, true)
    local counted = {}
    for c = 1, 3 do counted[c] = { 0, 0, 0, 0 } end
    on_tick(function()
      for c, list in ipairs(ends) do
        for k, e in ipairs(list) do
          for li = 1, 2 do
            local line = e.get_transport_line(LINES[li])
            local n = line.get_item_count()
            if n > 0 then
              counted[c][(k - 1) * 2 + li] = counted[c][(k - 1) * 2 + li] + n
              line.clear()
            end
          end
        end
      end
    end)
    local function counts()
      local flat = {}
      for c = 1, 3 do
        for i = 1, 4 do flat[#flat + 1] = counted[c][i] end
      end
      return flat
    end
    local names = { "splitter only", "lane splitter before", "lane splitter after" }
    measure(counts, function(rates)
      for c = 1, 3 do
        local r = { rates[c * 4 - 3], rates[c * 4 - 2], rates[c * 4 - 1], rates[c * 4] }
        report("F5 %s: out1 left %.3f right %.3f, out2 left %.3f right %.3f items/s (input one lane, %.1f)",
          names[c], r[1], r[2], r[3], r[4], RATE / 2)
        if c > 1 then
          for i = 1, 4 do
            assert(math.abs(r[i] - RATE / 8) <= RATE / 8 * 0.02,
              names[c] .. ": lane " .. i .. " carries " .. r[i] .. ", expected " .. RATE / 8)
          end
        end
      end
    end)
  end)
end)
