-- Spike S2 (throwaway): linked belts across surfaces (F2), inserter access to a hidden
-- network (F3), inserters putting items in (F4), lane balancing (F5). Runs only with the
-- `mb-spikes` setting. Results are logged with the prefix "MB-SPIKE" (factorio-current.log)
-- and recorded in docs/feasibility.md F2-F5. The save/load half of F2 runs on an MCP server
-- instance (see docs/feasibility.md), not here.

local D = defines.direction
local SA = script.active_mods["space-age"] ~= nil
local BELT = SA and "turbo-transport-belt" or "express-transport-belt"
local SPLITTER = SA and "turbo-splitter" or "express-splitter"
local UNDERGROUND = SA and "turbo-underground-belt" or "express-underground-belt"
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

local STATUS = {}
for k, v in pairs(defines.entity_status) do STATUS[v] = k end

local visible ---@type LuaSurface  nauvis, the player's surface
local hidden ---@type LuaSurface   the hidden network surface
local next_row = 0
local saved_bulk_bonus = 0
local saved_circuit = false

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

-- `len` belts (of `name`, default the tier belt) from `p` in direction `dir`; returns the
-- position after the last one.
local function belts(s, p, dir, len, name)
  for i = 0, len - 1 do
    ce(s, { name = name or BELT, position = step(p, dir, i), direction = dir })
  end
  return step(p, dir, len)
end

-- Saturated source: infinity chest at `p`, loader one tile further in `dir` putting items on
-- a belt that starts after it. Returns the position of the first belt tile and the loader.
local function source(s, p, dir, item)
  local chest = ce(s, { name = "infinity-chest", position = p })
  chest.set_infinity_container_filter(1, { name = item or "iron-plate", count = 100, mode = "exactly" })
  local loader = ce(s, { name = "mb-spike-io-loader", position = step(p, dir, 1), direction = dir, type = "output" })
  return step(p, dir, 2), loader
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

-- A fresh test area on both surfaces, with its chunks generated.
local function region()
  local o = origin()
  for _, s in ipairs({ visible, hidden }) do
    s.request_to_generate_chunks(o, 1)
    s.force_generate_chunk_requests()
  end
  prepare(visible, o)
  return o
end

describe("spike S2: hidden surface", function()
  before_all(function()
    visible = game.surfaces.nauvis
    hidden = game.create_surface("mb-spike-hidden", { width = 128, height = 4000 })
    hidden.generate_with_lab_tiles = true
    game.forces.player.set_surface_hidden(hidden, true)
    saved_bulk_bonus = game.forces.player.bulk_inserter_capacity_bonus
    saved_circuit = game.forces.player.recipes["electronic-circuit"].enabled
    game.forces.player.recipes["electronic-circuit"].enabled = true
    game.forces.player.bulk_inserter_capacity_bonus = 11
    report("S2 tier belt %s, full belt %d items/s; hidden surface hidden for player: %s",
      BELT, RATE, tostring(game.forces.player.get_surface_hidden(hidden)))
  end)

  after_all(function()
    game.forces.player.bulk_inserter_capacity_bonus = saved_bulk_bonus
    game.forces.player.recipes["electronic-circuit"].enabled = saved_circuit
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

  -- F3 share rig. On the hidden surface a splitter is fed from the west (row 0 of the test
  -- area, splitter at x 0). Output A (row 0) runs to a belt sink. Output B (row 1) ends in an
  -- inserter port for the block at K = (5, 1):
  --   chest1 / chest2 / filtered: loader into a 1-slot / 2-slot / 2-slot filtered buffer
  --     chest at K on the hidden surface, exposed by a proxy block at K on nauvis;
  --   belt: hidden input linked belt at (4, 1) linked to an output linked belt at K on nauvis
  --     (under an mb-spike-block), facing west, a dead end that inserters pick from;
  --   plain: vanilla control, no port at all: B ends in a plain dead-end belt at K on the
  --     hidden surface and the consumer stands there too.
  -- Feeds: iron (full belt of iron), lanes (iron on the left lane, copper cable on the right,
  -- one full lane each), mixed (iron and cable in irregular clumps on the left lane only,
  -- dropped by five bulk inserters), alternating (iron and cable strictly alternating on the
  -- right lane only, from a side-loaded column), lanes_late (lanes, but the cable lane starts
  -- 900 ticks after the iron lane).
  -- Consumers: inserters (three bulk inserters N, E, S of K into chests), assembler (one
  -- inserter east of K into an electronic-circuit assembler, output into a chest).
  local CABLE = "copper-cable"

  -- A feed belt of `len` tiles entering `target` from side `from` (a saturated source of `item`).
  -- Returns the source loader.
  local function feed_into(target, from, item, len)
    local to = OPPOSITE[from]
    local p, loader = source(hidden, step(target, from, len + 2), to, item)
    belts(hidden, p, to, len)
    return loader
  end

  local function build_rig(o, port, feed, consumer)
    assert(not (port == "plain" and consumer == "inserters"), "plain port only with the assembler")
    local items = feed == "iron" and { "iron-plate" } or { "iron-plate", CABLE }
    belts(hidden, at(o, -9, 0), D.east, 9)
    if feed == "iron" then
      source(hidden, at(o, -11, 0), D.east)
    elseif feed == "lanes" or feed == "lanes_late" then
      feed_into(at(o, -8, 0), D.north, "iron-plate", 3) -- north side of an east belt: left lane
      local cable = feed_into(at(o, -8, 0), D.south, CABLE, 3) -- south side: right lane
      if feed == "lanes_late" then
        -- the cable lane starts 900 ticks after the iron lane
        cable.disabled_by_script = true
        after_ticks(900, function() cable.disabled_by_script = false end)
      end
    elseif feed == "mixed" then
      -- inserters south of the main belt drop onto its far (north, left) lane
      local pattern = { "iron-plate", CABLE, CABLE, "iron-plate", CABLE }
      for i, item in ipairs(pattern) do
        local x = -9 + i
        local chest = ce(hidden, { name = "infinity-chest", position = at(o, x, 2) })
        chest.set_infinity_container_filter(1, { name = item, count = 100, mode = "exactly" })
        ce(hidden, { name = "mb-spike-inserter", position = at(o, x, 1), direction = D.south })
      end
    else
      -- a column carrying iron (left) and cable (right) side-loads into the south side of the
      -- main belt, so both end up interleaved on its right lane. The column is a yellow belt
      -- (7.5 items/s per lane), so the two lanes together fit into one tier lane; with a
      -- saturated column the merge lets only one of its lanes through.
      belts(hidden, at(o, -8, 5), D.north, 5, "transport-belt")
      feed_into(at(o, -8, 4), D.west, "iron-plate", 2)
      feed_into(at(o, -8, 4), D.east, CABLE, 2)
    end
    ce(hidden, { name = SPLITTER, position = { x = o.x, y = o.y + 0.5 }, direction = D.east })
    local rig = { items = items, outs = {}, inserters = {} }
    rig.a_loader = ce(hidden, { name = "mb-spike-io-loader", position = at(o, 4, 0), direction = D.east, type = "input" })
    rig.a = ce(hidden, { name = "mb-spike-sink", position = at(o, 5, 0) })
    belts(hidden, at(o, 1, 0), D.east, 3)
    belts(hidden, at(o, 1, 1), D.east, 3)
    local K = at(o, 5, 1)
    local cs = visible
    if port == "belt" then
      local hin = ce(hidden, { name = "mb-spike-lb", position = at(o, 4, 1), direction = D.east, type = "input" })
      ce(visible, { name = "mb-spike-block", position = K })
      rig.port = ce(visible, { name = "mb-spike-lb", position = K, direction = D.west, type = "output" })
      hin.connect_linked_belts(rig.port)
      rig.block = rig.port
    elseif port == "plain" then
      belts(hidden, at(o, 4, 1), D.east, 1)
      rig.port = ce(hidden, { name = BELT, position = K, direction = D.east })
      rig.block = rig.port
      cs = hidden
    else
      ce(hidden, { name = "mb-spike-io-loader", position = at(o, 4, 1), direction = D.east, type = "input" })
      local name = ({ chest1 = "mb-spike-buffer", chest2 = "mb-spike-buffer-2", filtered = "mb-spike-buffer-filtered" })[port]
      rig.buffer = ce(hidden, { name = name, position = K })
      if port == "filtered" then
        local inv = rig.buffer.get_inventory(defines.inventory.chest)
        for i, item in ipairs(items) do
          assert(inv.set_filter(i, { name = item }), "filter refused")
        end
      end
      rig.block = ce(visible, { name = "mb-spike-proxy", position = K })
      rig.block.proxy_target_entity = rig.buffer
      rig.block.proxy_target_inventory = defines.inventory.chest
    end
    if consumer == "inserters" then
      for _, dir in ipairs({ D.north, D.east, D.south }) do
        -- an inserter's direction points at its pickup side (the block)
        rig.inserters[#rig.inserters + 1] = ce(cs, {
          name = "mb-spike-inserter", position = step(K, dir, 1), direction = OPPOSITE[dir],
        })
        rig.outs[#rig.outs + 1] = ce(cs, { name = "mb-spike-sink", position = step(K, dir, 2) })
      end
    else
      rig.inserters[1] = ce(cs, { name = "mb-spike-inserter", position = step(K, D.east, 1), direction = D.west })
      rig.assembler = ce(cs, { name = "mb-spike-assembler", position = step(K, D.east, 3) })
      rig.assembler.set_recipe("electronic-circuit")
      ce(cs, { name = "mb-spike-inserter", position = step(K, D.east, 5), direction = D.west })
      rig.outs[1] = ce(cs, { name = "mb-spike-sink", position = step(K, D.east, 6) })
    end
    -- Per item: { A, B }. B counts everything that left the network through the port: the
    -- consumers' chests, the inserters' hands, the buffer and the port belt.
    function rig.counts()
      local c = {}
      for _, item in ipairs(items) do
        local b = 0
        for _, ch in ipairs(rig.outs) do b = b + ch.get_item_count(item) end
        for _, ins in ipairs(rig.inserters) do
          local h = ins.held_stack
          if h.valid_for_read and h.name == item then b = b + h.count end
        end
        if rig.buffer then b = b + rig.buffer.get_item_count(item) end
        if port == "belt" then
          for _, li in ipairs(LINES) do b = b + rig.port.get_transport_line(li).get_item_count({ name = item }) end
        end
        c[#c + 1] = rig.a.get_item_count(item)
        c[#c + 1] = b
      end
      return c
    end
    return rig
  end

  -- I1: one item; the inserters free, slow (partial demand), restarted, and with output A
  -- blocked. Expected from splitter semantics: half, the inserter's own rate with A getting
  -- the rest, half again, and everything up to the inserters' speed.
  for _, port in ipairs({ "chest1", "belt" }) do
    test("inserter_share_phases_" .. port, function()
      async((WARMUP + MEASURE) * 4 + 600)
      local rig = build_rig(region(), port, "iron", "inserters")
      after_ticks(5, function()
        for _, ins in ipairs(rig.inserters) do
          assert(ins.pickup_target == rig.block, "inserter picks from " .. tostring(ins.pickup_target and ins.pickup_target.name))
        end
      end)
      local function per_inserter()
        local t = {}
        for i, ch in ipairs(rig.outs) do t[i] = ch.get_item_count() end
        return table.concat(t, " / ")
      end
      local half = RATE / 2
      measure(rig.counts, function(free)
        report("F3 %s free: A %.3f, inserters %.3f items/s (half %.1f); per inserter chest %s",
          port, free[1], free[2], half, per_inserter())
        assert(math.abs(free[1] - half) <= half * 0.01 and math.abs(free[2] - half) <= half * 0.01,
          port .. ": free phase not half/half")
        rig.inserters[2].disabled_by_script = true
        rig.inserters[3].disabled_by_script = true
        rig.inserters[1].inserter_stack_size_override = 1
        measure(rig.counts, function(slow)
          report("F3 %s slow (one inserter, hand size 1): A %.3f, inserter %.3f, sum %.3f items/s",
            port, slow[1], slow[2], slow[1] + slow[2])
          assert(slow[2] < half * 0.9, port .. ": the slow inserter was not slower than its share")
          assert(math.abs(slow[1] + slow[2] - RATE) <= RATE * 0.01, port .. ": the unused share was not passed to A")
          for _, ins in ipairs(rig.inserters) do
            ins.disabled_by_script = false
            ins.inserter_stack_size_override = 0
          end
          measure(rig.counts, function(again)
            report("F3 %s restarted: A %.3f, inserters %.3f items/s", port, again[1], again[2])
            assert(math.abs(again[1] - half) <= half * 0.01 and math.abs(again[2] - half) <= half * 0.01,
              port .. ": not half/half after the restart")
            rig.a_loader.destroy()
            measure(rig.counts, function(blocked)
              report("F3 %s output A blocked: A %.3f, inserters %.3f items/s; per inserter chest %s",
                port, blocked[1], blocked[2], per_inserter())
              assert(blocked[1] == 0, port .. ": A still moved")
              assert(blocked[2] >= half * 0.99, port .. ": inserters got less than their share with A blocked")
            end)
            return true
          end)
          return true
        end)
        return true
      end)
    end)
  end

  -- C1: two item types, inserters free. Exact means the block gets the same amount of each
  -- item as belt output A.
  local MIXED_SHARE = {
    lanes = { "chest1", "chest2", "filtered", "belt" },
    mixed = { "chest1", "chest2", "filtered", "belt" },
    alternating = { "belt" },
  }
  for _, feed in ipairs({ "lanes", "mixed", "alternating" }) do
    for _, port in ipairs(MIXED_SHARE[feed]) do
      test("mixed_share_" .. feed .. "_" .. port, function()
        async(WARMUP + MEASURE + 300)
        local rig = build_rig(region(), port, feed, "inserters")
        measure(rig.counts, function(r)
          local held = "-"
          if rig.buffer then
            local inv = rig.buffer.get_inventory(defines.inventory.chest)
            local filters = inv.supports_filters() and { inv.get_filter(1), inv.get_filter(2) } or "none"
            held = serpent.line({ inv.get_contents(), filters })
          end
          report("F3 mixed %s %s: iron A %.3f B %.3f, cable A %.3f B %.3f items/s; buffer and filters at the end %s",
            feed, port, r[1], r[2], r[3], r[4], held)
          if port == "belt" and feed ~= "alternating" then
            for i = 1, 3, 2 do
              assert(math.abs(r[i] - r[i + 1]) <= r[i] * 0.03, "belt port: item share differs from A")
            end
          end
        end)
      end)
    end
  end

  -- C1: two item types, one inserter feeding an assembler that needs both (electronic
  -- circuit: 1 iron plate + 3 copper cable). A deadlock shows as 0 circuits per second.
  local MIXED_ASSEMBLER = {
    lanes = { "chest1", "chest2", "filtered", "belt", "plain" },
    mixed = { "chest1", "chest2", "filtered", "belt", "plain" },
    alternating = { "belt", "plain" },
    lanes_late = { "chest1", "chest2", "filtered", "belt", "plain" },
  }
  for _, feed in ipairs({ "lanes", "lanes_late", "mixed", "alternating" }) do
    for _, port in ipairs(MIXED_ASSEMBLER[feed]) do
      test("mixed_assembler_" .. feed .. "_" .. port, function()
        async(WARMUP * 2 + MEASURE + 300)
        local rig = build_rig(region(), port, feed, "assembler")
        local function made() return { rig.assembler.products_finished } end
        measure(made, function(r)
          local held = rig.buffer and serpent.line(rig.buffer.get_inventory(defines.inventory.chest).get_contents()) or "-"
          report("F3 assembler %s %s: %.3f circuits/s over %d ticks (max 1.5); buffer %s; assembler status %s",
            feed, port, r[1], MEASURE, held, STATUS[rig.assembler.status] or tostring(rig.assembler.status))
          if port == "belt" and (feed == "lanes" or feed == "lanes_late") then
            assert(r[1] >= 1.4, "belt port starved the assembler")
          end
        end, WARMUP * 2)
      end)
    end
  end

  -- F3: the proxy as the visible block shares its tile with one hidden linked belt (the F1
  -- block-tile interface). Which entity does an inserter pointed at that tile pick from?
  -- The east inserter's pickup_target is written to the proxy at tick 60; the west inserter
  -- is never written (control).
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
    local ctl = ce(visible, { name = "mb-spike-inserter", position = at(o, -1, 0), direction = D.east })
    local ctl_out = ce(visible, { name = "steel-chest", position = at(o, -2, 0) })
    local at_build = ins.pickup_target and ins.pickup_target.name or "nil"
    after_ticks(60, function()
      local iron, copper = out.get_item_count("iron-plate"), out.get_item_count("copper-plate")
      report("F3 tile with proxy + linked belt: pickup_target at build %s, after 60 ticks %s / control %s; taken so far: %d iron (proxy), %d copper (belt)",
        at_build, ins.pickup_target and ins.pickup_target.name or "nil",
        ctl.pickup_target and ctl.pickup_target.name or "nil", iron, copper + ctl_out.get_item_count("copper-plate"))
      assert(ins.pickup_target == lb and ctl.pickup_target == lb, "default pickup_target is not the linked belt")
      assert(iron == 0 and ctl_out.get_item_count("iron-plate") == 0, "an inserter took from the proxy by default")
      ins.pickup_target = proxy
      report("F3 tile with proxy + linked belt: pickup_target after writing %s",
        ins.pickup_target and ins.pickup_target.name or "nil")
    end)
    after_ticks(360, function()
      report("F3 tile with proxy + linked belt: written inserter took %d iron (proxy); control took %d iron, pickup_target %s",
        out.get_item_count("iron-plate"), ctl_out.get_item_count("iron-plate"),
        ctl.pickup_target and ctl.pickup_target.name or "nil")
      assert(ins.pickup_target == proxy, "pickup_target did not stay on the proxy")
      assert(out.get_item_count("iron-plate") > 0, "nothing taken from the proxy")
      assert(ctl_out.get_item_count("iron-plate") == 0 and ctl.pickup_target == lb,
        "the control inserter switched to the proxy on its own")
      done()
    end)
  end)

  -- I3 (a): the drop side of the same shared tile. An inserter drops onto a tile holding the
  -- proxy (target: a hidden chest) and an input linked belt (partner: a hidden belt sink).
  test("drop_target_on_shared_tile", function()
    async(900)
    local o = region()
    local target = ce(hidden, { name = "steel-chest", position = at(o, 0, -3) })
    local lb = ce(visible, { name = "mb-spike-lb", position = o, direction = D.north, type = "input" })
    local partner = ce(hidden, { name = "mb-spike-lb", position = o, direction = D.east, type = "output" })
    lb.connect_linked_belts(partner)
    local s = sink(hidden, belts(hidden, at(o, 1, 0), D.east, 3), D.east)
    local proxy = ce(visible, { name = "mb-spike-proxy", position = o })
    proxy.proxy_target_entity = target
    proxy.proxy_target_inventory = defines.inventory.chest
    local from = ce(visible, { name = "infinity-chest", position = at(o, -2, 0) })
    from.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
    local ins = ce(visible, { name = "mb-spike-inserter", position = at(o, -1, 0), direction = D.west })
    after_ticks(300, function()
      report("F3 drop onto proxy + linked belt: default drop_target %s; after 300 ticks %d on the belt side, %d in the proxy target",
        ins.drop_target and ins.drop_target.name or "nil", s.get_item_count() + items_on(partner), target.get_item_count())
      assert(ins.drop_target == proxy, "default drop_target is not the proxy")
      ins.drop_target = lb
    end)
    after_ticks(600, function()
      local before = s.get_item_count() + items_on(partner)
      after_ticks(200, function()
        report("F3 drop onto proxy + linked belt: after writing, drop_target %s, %d more items on the belt side",
          ins.drop_target and ins.drop_target.name or "nil", s.get_item_count() + items_on(partner) - before)
        assert(ins.drop_target == lb and s.get_item_count() + items_on(partner) > before, "writing drop_target did not stick")
        done()
      end)
    end)
  end)

  -- I3 (c): an inserter's pickup and drop positions are known the moment it is built, while
  -- pickup_target / drop_target are still nil, so a mod can find the block an inserter
  -- serves in on_built_entity without waiting a tick.
  test("inserter_positions_known_at_build", function()
    local o = region()
    local rows = {}
    for i, name in ipairs({ "inserter", "long-handed-inserter", "bulk-inserter" }) do
      local p = at(o, 0, i * 4)
      local ins = ce(visible, { name = name, position = p, direction = D.west })
      local pick, drop = ins.pickup_position, ins.drop_position
      rows[#rows + 1] = string.format("%s pickup (%+.2f, %+.2f) drop (%+.2f, %+.2f) pickup_target %s",
        name, pick.x - p.x, pick.y - p.y, drop.x - p.x, drop.y - p.y,
        ins.pickup_target and ins.pickup_target.name or "nil")
      local reach = name == "long-handed-inserter" and 2 or 1
      assert(math.floor(pick.x) == math.floor(p.x) - reach and math.floor(pick.y) == math.floor(p.y),
        name .. ": pickup position not on the tile west of it")
      assert(math.floor(drop.x) == math.floor(p.x) + reach and math.floor(drop.y) == math.floor(p.y),
        name .. ": drop position not on the tile east of it")
    end
    report("F3 positions at build (relative to the inserter, facing west): %s", table.concat(rows, "; "))
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

  -- F4 with the belt port: an inserter drops onto an input linked belt on the block tile
  -- (under the block), linked to the hidden network. A finite chest of 200 plates must
  -- arrive in full.
  test("inserter_puts_onto_belt_port", function()
    async(3000)
    local o = region()
    ce(visible, { name = "mb-spike-block", position = o })
    local port = ce(visible, { name = "mb-spike-lb", position = o, direction = D.north, type = "input" })
    local partner = ce(hidden, { name = "mb-spike-lb", position = o, direction = D.east, type = "output" })
    port.connect_linked_belts(partner)
    local s = sink(hidden, belts(hidden, at(o, 1, 0), D.east, 4), D.east)
    local from = ce(visible, { name = "steel-chest", position = at(o, -2, 0) })
    from.insert({ name = "iron-plate", count = 200 })
    local ins = ce(visible, { name = "mb-spike-inserter", position = at(o, -1, 0), direction = D.west })
    after_ticks(5, function()
      assert(ins.drop_target == port, "inserter does not drop onto the belt port")
    end)
    after_ticks(2400, function()
      report("F4 belt port: %d of 200 reached the network-side sink; %d left in the source",
        s.get_item_count(), from.get_item_count())
      assert(s.get_item_count() == 200, "not all 200 items reached the network side")
      done()
    end)
  end)

  -- The belt port next to F1 edges on all four sides: it must not connect to any of them.
  -- Every combination: output or input port (facing west) with output or input edges all
  -- round.
  test("belt_port_ignores_edges", function()
    local o = region()
    local function ring(c, port_type, edge_type)
      ce(visible, { name = "mb-spike-block", position = c })
      local port = ce(visible, { name = "mb-spike-lb", position = c, direction = D.west, type = port_type })
      local edges = {}
      for _, side in ipairs({ D.north, D.east, D.south, D.west }) do
        local dir = edge_type == "output" and side or OPPOSITE[side]
        local name = edge_type == "output" and "mb-spike-edge-out" or "mb-spike-edge"
        edges[#edges + 1] = ce(visible, { name = name, position = step(c, side, 1), direction = dir, type = edge_type })
      end
      local nb = port.belt_neighbours
      local edge_links = 0
      for _, e in ipairs(edges) do
        local enb = e.belt_neighbours
        edge_links = edge_links + #enb.inputs + #enb.outputs
      end
      report("F3 %s port among %s edges: port %d inputs %d outputs, edges %d belt neighbours in total",
        port_type, edge_type, #nb.inputs, #nb.outputs, edge_links)
      assert(#nb.inputs == 0 and #nb.outputs == 0 and edge_links == 0, port_type .. " port connects to an edge")
    end
    ring(o, "output", "output")
    ring(at(o, 6, 0), "input", "input")
    ring(at(o, 0, 6), "output", "input")
    ring(at(o, 6, 6), "input", "output")
  end)

  -- N1: what an output belt port does to the belt-connectable entity in front of it. The port
  -- (on nauvis, facing east, under a block) is fed by a saturated hidden input linked belt.
  -- After 600 ticks, `leaked` counts the items that went past the port into the neighbour and
  -- whatever follows it. The question is also whether `belt_neighbours.outputs` of the port
  -- shows each leak, so a mod can detect it.
  local function fed_port(c, dir)
    local hin = ce(hidden, { name = "mb-spike-lb", position = c, direction = D.east, type = "input" })
    belts(hidden, source(hidden, at(c, -5, 0), D.east), D.east, 3)
    ce(visible, { name = "mb-spike-block", position = c })
    local port = ce(visible, { name = "mb-spike-lb", position = c, direction = dir, type = "output" })
    hin.connect_linked_belts(port)
    return port
  end

  ---@param list LuaEntity[]
  ---@return integer
  local function items_of(list)
    local n = 0
    for _, e in ipairs(list) do
      if e.type == "container" then
        n = n + e.get_item_count()
      else
        for i = 1, e.get_max_transport_line_index() do
          n = n + e.get_transport_line(i --[[@as defines.transport_line]]).get_item_count()
        end
      end
    end
    return n
  end

  test("belt_port_front_neighbours", function()
    async(900)
    local o = region()
    local cases = {}
    local function case(name, build)
      local i = #cases
      local c = at(o, -12 + (i % 2) * 14, math.floor(i / 2) * 6 - 12)
      local port = fed_port(c, D.east)
      cases[#cases + 1] = { name = name, port = port, watch = build(step(c, D.east, 1), c) }
    end
    case("nothing", function() return {} end)
    case("passing belt (perpendicular, going north)", function(f)
      local list = {}
      for dy = 1, -3, -1 do
        list[#list + 1] = ce(visible, { name = BELT, position = at(f, 0, dy), direction = D.north })
      end
      return list
    end)
    case("belt pointing at the port (head-on)", function(f)
      return { ce(visible, { name = BELT, position = f, direction = D.west }) }
    end)
    local function block_with_input_port(f, dir)
      ce(visible, { name = "mb-spike-block", position = f })
      local p = ce(visible, { name = "mb-spike-lb", position = f, direction = dir, type = "input" })
      local hp = ce(hidden, { name = "mb-spike-lb", position = f, direction = D.east, type = "output" })
      p.connect_linked_belts(hp)
      local list = { p, hp }
      for i = 1, 3 do list[#list + 1] = ce(hidden, { name = BELT, position = at(f, i, 0), direction = D.east }) end
      return list
    end
    case("next block's input port, back to the port", function(f) return block_with_input_port(f, D.east) end)
    case("next block's input port, side to the port", function(f) return block_with_input_port(f, D.north) end)
    case("next block's output port, side to the port", function(f)
      ce(visible, { name = "mb-spike-block", position = f })
      return { ce(visible, { name = "mb-spike-lb", position = f, direction = D.north, type = "output" }) }
    end)
    case("underground entrance", function(f)
      return {
        ce(visible, { name = UNDERGROUND, position = f, direction = D.east, type = "input" }),
        ce(visible, { name = UNDERGROUND, position = at(f, 3, 0), direction = D.east, type = "output" }),
      }
    end)
    case("underground exit facing away", function(f)
      return { ce(visible, { name = UNDERGROUND, position = f, direction = D.east, type = "output" }) }
    end)
    case("splitter", function(f)
      return {
        ce(visible, { name = SPLITTER, position = { x = f.x, y = f.y + 0.5 }, direction = D.east }),
        ce(visible, { name = BELT, position = at(f, 1, 0), direction = D.east }),
        ce(visible, { name = BELT, position = at(f, 1, 1), direction = D.east }),
      }
    end)
    case("loader into a chest", function(f)
      ce(visible, { name = "mb-spike-io-loader", position = f, direction = D.east, type = "input" })
      return { ce(visible, { name = "steel-chest", position = at(f, 1, 0) }) }
    end)
    after_ticks(600, function()
      for _, k in ipairs(cases) do
        local outs = {}
        for _, e in ipairs(k.port.belt_neighbours.outputs) do outs[#outs + 1] = e.name end
        local leaked = items_of(k.watch)
        report("N1 output port facing %s: leaked %d items in 600 ticks; port belt_neighbours.outputs {%s}",
          k.name, leaked, table.concat(outs, ", "))
        assert((leaked > 0) == (#outs > 0), k.name .. ": belt_neighbours.outputs does not match the leak")
      end
      done()
    end)
  end)

  -- N1 rule: try the four directions and keep the first whose belt_neighbours.outputs is
  -- empty; refuse when there is none. A belt built in front of the chosen side later shows up
  -- in belt_neighbours.outputs at once, so on_built_entity can re-check.
  ---@return LuaEntity?
  local function place_port(c, partner)
    for _, dir in ipairs({ D.north, D.east, D.south, D.west }) do
      local port = ce(visible, { name = "mb-spike-lb", position = c, direction = dir, type = "output" })
      if #port.belt_neighbours.outputs == 0 then
        partner.connect_linked_belts(port)
        return port
      end
      port.destroy()
    end
    return nil
  end

  test("belt_port_picks_free_side", function()
    async(900)
    local o = region()
    local c = at(o, -4, 0)
    local hin = ce(hidden, { name = "mb-spike-lb", position = c, direction = D.east, type = "input" })
    belts(hidden, source(hidden, at(c, -5, 0), D.east), D.east, 3)
    ce(visible, { name = "mb-spike-block", position = c })
    -- north and south: belts passing east to west; east: an underground entrance; west: free
    local watch = {}
    for _, dy in ipairs({ -1, 1 }) do
      for dx = 0, 1 do
        watch[#watch + 1] = ce(visible, { name = BELT, position = at(c, dx, dy), direction = D.west })
      end
    end
    watch[#watch + 1] = ce(visible, { name = UNDERGROUND, position = at(c, 1, 0), direction = D.east, type = "input" })
    watch[#watch + 1] = ce(visible, { name = UNDERGROUND, position = at(c, 4, 0), direction = D.east, type = "output" })
    local port = assert(place_port(c, hin), "no free side found")
    assert(port.direction == D.west, "chose direction " .. port.direction .. ", expected west")
    -- a fully surrounded block: the same, plus a belt passing on the west
    local c2 = at(o, -4, 8)
    local hin2 = ce(hidden, { name = "mb-spike-lb", position = c2, direction = D.east, type = "input" })
    ce(visible, { name = "mb-spike-block", position = c2 })
    for _, dy in ipairs({ -1, 1 }) do
      for dx = 0, 1 do ce(visible, { name = BELT, position = at(c2, dx, dy), direction = D.west }) end
    end
    for dy = -1, 1 do ce(visible, { name = BELT, position = at(c2, -1, dy), direction = D.south }) end
    ce(visible, { name = UNDERGROUND, position = at(c2, 1, 0), direction = D.east, type = "input" })
    ce(visible, { name = UNDERGROUND, position = at(c2, 4, 0), direction = D.east, type = "output" })
    local none = place_port(c2, hin2)
    after_ticks(600, function()
      local leaked = items_of(watch)
      report("N1 port placement: chose %s with belts on two sides and an underground on the third; leaked %d items in 600 ticks; surrounded block: %s",
        port.direction == D.west and "west" or tostring(port.direction), leaked, none and "placed (wrong)" or "refused")
      assert(leaked == 0, "items leaked from the chosen side")
      assert(none == nil, "a port was placed on a block with no free side")
      -- re-check: a belt built across the chosen side is visible at once
      ce(visible, { name = BELT, position = at(c, -1, 0), direction = D.north })
      report("N1 port re-check: after building a belt in front, belt_neighbours.outputs has %d entries",
        #port.belt_neighbours.outputs)
      assert(#port.belt_neighbours.outputs == 1, "the new front belt is not in belt_neighbours.outputs")
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
