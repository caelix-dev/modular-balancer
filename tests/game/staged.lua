-- Staged rebuilds (Plan 3 Task 5, Review Focus 5 rebuild_cost_is_bounded) and the parked Plan 2
-- items M9: the flush handler's work per tick is bounded (balancer.tick_budget, lowered here so
-- that small balancers take many ticks), every item is counted on every tick in between, and
-- the handler goes away when the work is done. Also eggs spoiling on the hidden surface, a space
-- platform as the visible side and balancers of two forces side by side.
-- Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local builder = require("scripts.builder")
local groups = require("scripts.groups")
local network = require("scripts.network")

local D = defines.direction
local ITEM = "iron-plate"
local default_budget = balancer.tick_budget
local default_flush = balancer.flush

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

local function rec_of(block)
  local id = groups.of(block.unit_number)
  return assert(balancer.get(id), "no balancer for group " .. tostring(id)), id
end

local function nm(rec)
  return rec.n .. ":" .. rec.m
end

-- Stops an output (H.sink result): its loader goes, so the belts and the network back up.
local function stop(out)
  out.loader.destroy()
end

-- Counts the handler's flushes (the handler calls balancer.flush through the module table) and
-- passes the budget on. Restored in after_each.
---@return { n: integer, count: fun(): integer }
local function count_flushes()
  local c = { n = 0 }
  c.count = function()
    return c.n
  end
  balancer.flush = function(budget)
    c.n = c.n + 1
    return default_flush(budget)
  end
  return c
end

-- Every region the allocator has in use belongs to a network of a balancer, a staged
-- placement, or a removed network still being taken out: none leaked, none freed twice.
local function regions_match(what)
  local st = storage.balancer
  local nets = 0
  for _, rec in pairs(st.recs) do
    for _, p in ipairs(balancer.nets_of(rec)) do
      if p.origin then
        nets = nets + 1
      end
    end
  end
  for _, job in pairs(st.jobs or {}) do
    if job.b and job.b.placed.origin then
      nets = nets + 1
    end
  end
  for _, sp in ipairs(st.spill_queue or {}) do
    for _, p in ipairs(sp.nets) do
      if p.origin then
        nets = nets + 1
      end
    end
  end
  local used = table_size(storage.regions and storage.regions.used or {})
  assert(used == nets, what .. ": " .. used .. " regions in use, " .. nets .. " networks")
end

-- Calls `check(ticks)` every tick while the balancer has work (at most `limit` ticks), then
-- `finish(ticks)`.
local function each_tick(limit, check, finish)
  local ticks = 0
  local function step()
    after_ticks(1, function()
      ticks = ticks + 1
      check(ticks)
      if balancer.pending(storage.balancer) then
        assert(ticks < limit, "staged work not finished after " .. limit .. " ticks")
        step()
      else
        finish(ticks)
      end
    end)
  end
  step()
end

describe("staged", function()
  after_each(function()
    balancer.tick_budget = default_budget
    balancer.flush = default_flush
    builder.max_buffer_slots = 65535
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- A backed-up 1:1 balancer gets a second output with a tiny budget: the new network is placed
  -- over several ticks while the old one runs, then the old one drains into it over several
  -- more. Every item is there on every tick, the handler stops afterwards, no region leaks.
  test("staged_rebuild_spreads_over_ticks", function()
    async(3000)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 2000 })
    stop(H.sink(o, 4, 4, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      assert(total == 2000, "before: " .. total)
      local rec0, id = rec_of(b)
      local held = H.network_of(id)
      assert(held > 20, "test setup: the network holds only " .. held)
      local old = rec0.placed
      balancer.tick_budget = 150
      local c = count_flushes()
      stop(H.sink(o, 4, 4, D.south, 3)) -- raise_built marks the group; the handler does the rest
      local saw_job, saw_drain = false, false
      each_tick(2000, function(t)
        local st = storage.balancer
        saw_job = saw_job or next(st.jobs) ~= nil
        local rec = balancer.get(id)
        saw_drain = saw_drain or (rec ~= nil and rec.draining ~= nil and #rec.draining > 0)
        local n = H.count_box(box, ITEM)
        assert(n == total, "tick " .. t .. ": " .. n .. " of " .. total)
      end, function(t)
        local rec = rec_of(b)
        H.report("staged rebuild 1:1 -> 1:2 (budget 150, %d items in the network): %d ticks, %d flushes", held, t, c.n)
        assert(saw_job and saw_drain, "no staged placement or drain seen (" .. tostring(saw_job) .. ", " .. tostring(saw_drain) .. ")")
        assert(t > 5, "done in " .. t .. " ticks: the work was not spread")
        assert(nm(rec) == "1:2" and rec.placed ~= old, "network " .. nm(rec))
        assert(#(rec.draining or {}) == 0 and #rec.extra == 0, "old networks left over")
        for _, e in ipairs(old.entities) do
          assert(not e.valid, "an entity of the old network is left")
        end
        regions_match("after the rebuild")
        local n0 = c.n
        after_ticks(30, function()
          assert(c.n == n0, (c.n - n0) .. " flushes in 30 idle ticks: the handler is still registered")
          assert(H.count_box(box, ITEM) == total, "at the end: " .. H.count_box(box, ITEM))
          done()
        end)
      end)
    end)
  end)

  -- The group changes shape while its new network is still being placed: the placement is
  -- dropped (it holds nothing) and a new one starts for the new shape. Nothing lost, no region
  -- leaked.
  test("staged_placement_restarts_when_the_group_changes", function()
    async(4000)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 2000 })
    stop(H.sink(o, 4, 4, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, id = rec_of(b)
      balancer.tick_budget = 40
      stop(H.sink(o, 4, 4, D.south, 3))
      -- waits for the placement to be half done (generated, planned, some entities created)
      local waited = 0
      local function half_done()
        local j = storage.balancer.jobs[id] --[[@as table?]]
        return j and j.b and j.b.i > 1 and j.b.i <= #j.b.ops and j or nil
      end
      local function wait(k)
        after_ticks(1, function()
          waited = waited + 1
          if half_done() then
            k()
          else
            assert(waited < 200 and storage.balancer.jobs[id], "test setup: no placement half done")
            wait(k)
          end
        end)
      end
      wait(function()
        local job = half_done() --[[@as table]]
        local first = job.b.placed
        stop(H.sink(o, 4, 4, D.north, 3))
        local restarted = false
        each_tick(4000, function(t)
          local j = storage.balancer.jobs[id] --[[@as table?]]
          restarted = restarted or (j ~= nil and j.key ~= job.key)
          assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
        end, function(t)
          local rec = rec_of(b)
          assert(restarted, "the placement was not restarted for the new shape")
          assert(nm(rec) == "1:3", "network " .. nm(rec))
          for _, e in ipairs(first.entities) do
            assert(not e.valid, "an entity of the dropped placement is left")
          end
          regions_match("after the restart")
          H.report("staged placement restarted: done %d ticks after the second change", t)
          done()
        end)
      end)
    end)
  end)

  -- The last block of a full balancer is removed with nobody to take its items: the network is
  -- taken out a budget's worth per tick and spilled next to the group. Every item is in the
  -- box (network or ground) on every tick.
  test("staged_removal_spills_over_ticks", function()
    async(3000)
    local o, box = area(12, 12)
    local b = H.block(o, 5, 5, H.TIER)
    H.feed(o, 5, 5, D.west, 3, { stock = 1500 })
    stop(H.sink(o, 5, 5, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, id = rec_of(b)
      local held = H.network_of(id)
      assert(held > 20, "test setup: the network holds only " .. held)
      balancer.tick_budget = 100
      b.destroy({ raise_destroy = true })
      local saw_queue = false
      each_tick(2000, function(t)
        saw_queue = saw_queue or #storage.balancer.spill_queue > 0
        assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
      end, function(t)
        assert(saw_queue, "the removed network was not queued")
        assert(#storage.balancer.spill_queue == 0, "spills left")
        regions_match("after the removal")
        H.report("staged removal: %d items taken out and spilled over %d ticks", held, t)
        done()
      end)
    end)
  end)

  -- Two running balancers are joined with a tiny budget: the merged group's network is placed
  -- over several ticks, then both old networks drain into it. Nothing lost.
  test("staged_merge_drains_both_networks", function()
    async(4000)
    local o, box = area(12, 12)
    local a = H.block(o, 3, 4, H.TIER)
    local b = H.block(o, 5, 4, H.TIER)
    H.feed(o, 3, 4, D.west, 3, { stock = 500 })
    H.feed(o, 5, 4, D.east, 3, { stock = 500 })
    for _, x in ipairs({ 3, 5 }) do
      for y = 5, 7 do
        H.put(o, x, y, H.BELT, D.south)
      end
    end
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      assert(total == 1000, "before: " .. total)
      balancer.tick_budget = 120
      H.block(o, 4, 4, H.TIER)
      each_tick(3000, function(t)
        assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
      end, function(t)
        local rec, id = rec_of(a)
        assert(groups.of(b.unit_number) == id, "the blocks did not merge")
        assert(nm(rec) == "2:2", "network " .. nm(rec))
        assert(#rec.extra == 0 and #(rec.draining or {}) == 0, "old networks left over")
        assert(#game.surfaces.nauvis.find_entities_filtered({ area = box, type = "item-entity" }) == 0, "items spilled")
        regions_match("after the merge")
        H.report("staged merge: done in %d ticks", t)
        done()
      end)
    end)
  end)

  -- Many item kinds that cannot merge, and a buffer capped at one slot: a shrink whose old
  -- network cannot fit on the new belts gets stuck. The rest of the items wait, counted, in the
  -- sealed old network, and no tick handler keeps retrying. Once the buffer may grow, the next
  -- refresh of the group finishes the drain.
  test("stuck_drain_keeps_items_and_resumes", function()
    async(4000)
    local o, box = area(12, 12)
    local b = H.block(o, 5, 5, H.TIER)
    local kinds = { "iron-plate", "copper-plate", "steel-plate", "iron-gear-wheel" }
    H.feed(o, 5, 5, D.west, 3, { stock = 400, item = kinds[1] })
    H.feed(o, 5, 5, D.north, 3, { stock = 400, item = kinds[2] })
    local f3 = H.feed(o, 5, 5, D.south, 2, { stock = 0 })
    -- a third input with two more kinds on its two lanes
    f3.chest.insert({ name = kinds[3], count = 200 })
    f3.chest.insert({ name = kinds[4], count = 200 })
    stop(H.sink(o, 5, 5, D.east, 3))
    balancer.flush()
    after_ticks(900, function()
      local total = H.count_box(box)
      local rec0, id = rec_of(b)
      assert(nm(rec0) == "3:1", "test setup: network " .. nm(rec0))
      local held = H.network_of(id)
      assert(held > 30, "test setup: the network holds only " .. held)
      builder.max_buffer_slots = 1
      -- the north input goes: its last tile is an edge; mined with its items into a chest (the
      -- belt item it gives back is counted from here on)
      local edge = assert(H.at(o, 5, 4, "linked-belt"), "no north edge")
      local keep = H.ce(game.surfaces.nauvis, { name = "mb-test-chest", position = { o.x + 11, o.y + 11 } })
      assert(edge.mine({ inventory = keep.get_inventory(defines.inventory.chest), raise_destroyed = true }), "edge not mined")
      total = H.count_box(box)
      local c = count_flushes()
      balancer.flush()
      local rec = rec_of(b)
      assert(nm(rec) == "2:1", "network " .. nm(rec))
      assert(#(rec.draining or {}) == 1, "test setup: the drain did not get stuck (" .. #(rec.draining or {}) .. " old networks)")
      assert(next(storage.balancer.drains) == nil, "a stuck drain is still scheduled")
      assert(H.count_box(box) == total, "stuck: " .. H.count_box(box) .. " of " .. total)
      local n0 = c.n
      after_ticks(30, function()
        assert(c.n == n0, (c.n - n0) .. " flushes in 30 ticks: a stuck drain retries every tick")
        assert(H.count_box(box) == total, "30 ticks later: " .. H.count_box(box) .. " of " .. total)
        -- no event touches the group: the periodic retry (every 300 ticks while a drain is
        -- stuck) resumes it once the buffer may grow
        builder.max_buffer_slots = 65535
        after_ticks(320, function()
          local rec2 = rec_of(b)
          assert(#(rec2.draining or {}) == 0, "the drain did not resume by itself")
          assert(next(storage.balancer.stuck) == nil, "still marked stuck")
          assert(H.count_box(box) == total, "after the resumed drain: " .. H.count_box(box) .. " of " .. total)
          regions_match("after the resumed drain")
          local n1 = c.n
          after_ticks(330, function()
            assert(c.n == n1, (c.n - n1) .. " flushes after the drain finished: something still runs")
            done()
          end)
        end)
      end)
    end)
  end)

  -- M9: an egg that spoils on the hidden surface (Space Age). On a normal surface a biter egg
  -- hatches a biter; on the hidden surface (no-enemies mode) nothing hatches, and the network's
  -- entities cannot be damaged anyway (destructible = false). The network keeps working.
  test("egg_spoils_on_the_hidden_surface", function()
    async(1200)
    if not prototypes.item["biter-egg"] then
      done()
      return
    end
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 300 })
    local out = H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local rec = rec_of(b)
    local put = 0
    for _, e in ipairs(rec.placed.entities) do
      assert(not e.destructible, "a network entity can be damaged: " .. e.name)
      if e.type == "linked-belt" and put < 4 then
        local line = e.get_transport_line(1)
        for _, egg in ipairs({ "biter-egg", "pentapod-egg" }) do
          if prototypes.item[egg] and line.can_insert_at(0) and line.insert_at(0, { name = egg, count = 1 }, 1) then
            local d = line.get_detailed_contents()
            d[#d].stack.spoil_percent = 0.999
            put = put + 1
          end
        end
      end
    end
    assert(put > 0, "test setup: no egg put on the network")
    after_ticks(900, function()
      local hidden = rec.placed.entities[1].surface
      assert(#hidden.find_entities_filtered({ force = "enemy" }) == 0, "something hatched on the hidden surface")
      for _, e in ipairs(rec.placed.entities) do
        assert(e.valid, "a network entity was destroyed")
      end
      for _, egg in ipairs({ "biter-egg", "pentapod-egg" }) do
        assert(H.count_box(box, egg) == 0, "an egg did not spoil")
      end
      assert(out.chest.get_item_count(ITEM) > 100, "the balancer stopped: " .. out.chest.get_item_count(ITEM))
      assert(H.count_box(box, ITEM) == 300, "plates: " .. H.count_box(box, ITEM))
      done()
    end)
  end)

  -- M9: a space platform as the visible side (Space Age): blocks, belts and chests on platform
  -- foundation. The network on the hidden surface balances them; removing the last block with
  -- nobody to take the items puts them in the platform's hub (no robots can fetch items lying
  -- in space).
  test("platform_as_the_visible_side", function()
    async(1500)
    if not script.active_mods["space-age"] then
      done()
      return
    end
    local p = assert(game.forces.player.create_space_platform({ name = "mb-test-platform-2", planet = "nauvis", starter_pack = "space-platform-starter-pack" }), "no platform")
    p.apply_starter_pack()
    local s = p.surface
    local hub = assert(p.hub, "no hub")
    local tiles = {}
    for x = 10, 24 do
      for y = -6, 6 do
        tiles[#tiles + 1] = { name = "space-platform-foundation", position = { x, y } }
      end
    end
    s.set_tiles(tiles)
    local function put(x, y, name, dir, t)
      t = t or {}
      t.name, t.position, t.direction, t.force, t.raise_built = name, { x + 0.5, y + 0.5 }, dir, "player", true
      return assert(s.create_entity(t), "could not build " .. name)
    end
    local blk = put(17, 0, "mb-balancer-" .. H.TIER)
    -- input from the west, outputs east and south
    local src = put(13, 0, "mb-test-chest")
    src.insert({ name = ITEM, count = 3000 })
    put(14, 0, "mb-test-loader-" .. H.TIER, D.east, { type = "output" })
    put(15, 0, H.BELT, D.east)
    put(16, 0, H.BELT, D.east)
    put(18, 0, H.BELT, D.east)
    put(19, 0, "mb-test-loader-" .. H.TIER, D.east, { type = "input" })
    local east = put(20, 0, "mb-test-chest")
    put(17, 1, H.BELT, D.south)
    put(17, 2, "mb-test-loader-" .. H.TIER, D.south, { type = "input" })
    local south = put(17, 3, "mb-test-chest")
    balancer.flush()
    local rec = rec_of(blk)
    assert(nm(rec) == "1:2", "network " .. nm(rec))
    assert(rec.placed.entities[1].surface.name == "mb-hidden", "the network is not on the hidden surface")
    local BELTISH = { ["transport-belt"] = true, ["loader-1x1"] = true, ["linked-belt"] = true }
    -- plates on the platform's foundation (chests, belts, loaders, the ground) and in the network
    local function count()
      ---@type number
      local n = 0
      for _, e in ipairs(s.find_entities_filtered({ area = { { 10, -6 }, { 25, 7 } } })) do
        if e.type == "container" then
          n = n + e.get_item_count(ITEM)
        elseif e.type == "item-entity" then
          n = n + (e.stack.name == ITEM and e.stack.count or 0)
        elseif BELTISH[e.type] then
          for i = 1, e.get_max_transport_line_index() do
            n = n + e.get_transport_line(i --[[@as defines.transport_line]]).get_item_count(ITEM)
          end
        end
      end
      for _, q in ipairs(balancer.nets_of(rec)) do
        for _, it in ipairs(builder.contents(q)) do
          n = n + (it.name == ITEM and it.count or 0)
        end
      end
      return n
    end
    after_ticks(600, function()
      local e, so = east.get_item_count(ITEM), south.get_item_count(ITEM)
      assert(e > 100 and math.abs(e - so) <= 2, "outputs " .. e .. " / " .. so)
      assert(count() == 3000, "on the platform: " .. count())
      -- back up so the network holds items, then remove the block with nobody to take them
      east.destroy()
      south.destroy()
      after_ticks(300, function()
        local inside = 0
        for _, it in ipairs(builder.contents(rec.placed)) do
          inside = inside + it.count
        end
        assert(inside > 0, "test setup: the network is empty")
        local left = count()
        local hub0 = hub.get_item_count(ITEM)
        -- a small budget: the network is taken out over several ticks, every item counted
        balancer.tick_budget = 60
        blk.destroy({ raise_destroy = true })
        each_tick(2000, function(t)
          local now, to_hub = count(), hub.get_item_count(ITEM) - hub0
          assert(now + to_hub == left, "tick " .. t .. ": " .. now .. " + " .. to_hub .. " in the hub, expected " .. left)
        end, function(t)
          local to_hub = hub.get_item_count(ITEM) - hub0
          assert(t > 1, "test setup: the removal was not spread over ticks")
          assert(to_hub >= inside, "the hub got " .. to_hub .. " of the network's " .. inside)
          assert(count() + to_hub == left, "after the removal: " .. count() .. " + " .. to_hub .. " in the hub, expected " .. left)
          p.destroy()
          done()
        end)
      end)
    end)
  end)

  -- M9, cross-force: blocks of two forces side by side are two groups, each with its own
  -- network owned by its own force, and each balances only its own belts.
  test("two_forces_side_by_side", function()
    async(1200)
    local o, box = area(12, 10)
    local other = game.forces["mb-test-other"] or game.create_force("mb-test-other")
    local a = H.block(o, 4, 4, H.TIER)
    local b = H.block(o, 5, 4, H.TIER, other)
    H.feed(o, 4, 4, D.west, 3, { stock = 300 })
    local outa = H.sink(o, 4, 4, D.north, 3)
    -- force B's input and output, built as force B
    local function put_b(dx, dy, name, dir, t)
      t = t or {}
      t.force = other
      return H.put(o, dx, dy, name, dir, t)
    end
    local src = put_b(5, 9, "mb-test-chest")
    src.insert({ name = "copper-plate", count = 300 })
    put_b(5, 8, "mb-test-loader-" .. H.TIER, D.north, { type = "output" })
    put_b(5, 7, H.BELT, D.north)
    put_b(5, 6, H.BELT, D.north)
    put_b(5, 5, H.BELT, D.north)
    put_b(6, 4, H.BELT, D.east)
    put_b(7, 4, H.BELT, D.east)
    put_b(8, 4, "mb-test-loader-" .. H.TIER, D.east, { type = "input" })
    local outb = put_b(9, 4, "mb-test-chest")
    balancer.flush()
    local ra, ida = rec_of(a)
    local rb, idb = rec_of(b)
    assert(ida ~= idb, "the two forces' blocks are one group")
    assert(nm(ra) == "1:1" and nm(rb) == "1:1", "networks " .. nm(ra) .. " and " .. nm(rb))
    assert(ra.placed.entities[1].force.name == "player" and rb.placed.entities[1].force.name == "mb-test-other",
      "a network is owned by the wrong force")
    after_ticks(900, function()
      local ia, ib = outa.chest.get_item_count(ITEM), outb.get_item_count("copper-plate")
      assert(ia > 100 and ib > 100, "delivered " .. ia .. " iron (A) and " .. ib .. " copper (B)")
      assert(outa.chest.get_item_count("copper-plate") == 0 and outb.get_item_count(ITEM) == 0, "items crossed between the forces")
      assert(H.count_box(box, ITEM) == 300 and H.count_box(box, "copper-plate") == 300, "items lost")
      done()
    end)
  end)
  -- Review fix round. Each case below was reproduced in game by the T5b review.

  -- C1: a belt laid between two running balancers while their rebuilds are pending (tiny
  -- budget) is a shared tile beyond the old networks' port counts. It used to crash the game
  -- (link_shared linked a port with no network side); it is linked once the new networks are
  -- complete.
  test("shared_tile_while_rebuilds_are_pending", function()
    async(3000)
    local o, box = area(12, 12)
    local a = H.block(o, 3, 4, H.TIER)
    local b = H.block(o, 5, 4, H.TIER)
    H.feed(o, 3, 4, D.west, 2, { stock = 600 })
    H.sink(o, 3, 4, D.north, 2)
    H.feed(o, 5, 4, D.south, 2, { stock = 600 })
    H.sink(o, 5, 4, D.east, 2)
    balancer.flush()
    assert(nm(rec_of(a)) == "1:1" and nm(rec_of(b)) == "1:1", "test setup: two 1:1 balancers expected")
    after_ticks(120, function()
      local total = H.count_box(box, ITEM)
      balancer.tick_budget = 150
      H.put(o, 4, 4, H.BELT, D.east) -- A's second output, B's second input: a shared tile
      each_tick(3000, function(t)
        assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
      end, function(t)
        assert(nm(rec_of(a)) == "1:2" and nm(rec_of(b)) == "2:1", "networks " .. nm(rec_of(a)) .. " and " .. nm(rec_of(b)))
        regions_match("after the shared tile")
        H.report("shared tile while rebuilds are pending: done in %d ticks", t)
        after_ticks(300, function()
          assert(H.count_box(box, ITEM) == total, "300 ticks later: " .. H.count_box(box, ITEM) .. " of " .. total)
          done()
        end)
      end)
    end)
  end)

  -- C2: a removed group's network goes to a group whose refresh is deferred (no record yet:
  -- the block was replaced by another tier), and that group goes too before its refresh. Its
  -- items used to be deleted (the fresh record had no place to spill them).
  test("donated_network_of_a_deferred_group_that_goes", function()
    async(1500)
    local o, box = area(20, 12)
    local z = H.block(o, 14, 4, H.TIER)
    H.feed(o, 14, 4, D.north, 2, { stock = 10 })
    H.sink(o, 14, 4, D.south, 2)
    local a = H.block(o, 5, 5, H.TIER)
    H.feed(o, 5, 5, D.west, 3, { stock = 1500 })
    stop(H.sink(o, 5, 5, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, zid = rec_of(z)
      local _, aid = rec_of(a)
      assert(zid < aid, "test setup: ids " .. zid .. ", " .. aid)
      local held = H.network_of(aid)
      assert(held > 0, "test setup: the network is empty")
      balancer.mark({ zid }) -- refreshed first, it spends the budget
      local pos = a.position
      a.destroy({ raise_destroy = true })
      local t = game.surfaces.nauvis.create_entity({ name = "mb-balancer-fast", position = pos, force = "player", raise_built = true })
      assert(t, "test setup: no fast block")
      balancer.flush(1)
      local tid = groups.of(t.unit_number)
      local trec = balancer.get(tid)
      assert(trec and #trec.extra > 0 and storage.balancer.dirty[tid], "test setup: the network did not go to a deferred group")
      t.destroy({ raise_destroy = true })
      balancer.flush()
      local n = H.count_box(box, ITEM)
      H.report("deferred target then gone: %d of %d (the network held %d)", n, total, held)
      assert(n == total, "items deleted: " .. n .. " of " .. total)
      done()
    end)
  end)

  -- I1: the group's force is merged into another while its new network is half placed. The
  -- placement goes on with the new force and completes.
  test("force_merge_mid_placement", function()
    async(3000)
    local src = game.forces["mb-test-src"] or game.create_force("mb-test-src")
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER, src)
    local function putf(dx, dy, name, dir, t)
      t = t or {}
      t.force = src
      return H.put(o, dx, dy, name, dir, t)
    end
    for k = 1, 3 do
      putf(4 - k, 4, H.BELT, D.east)
    end
    putf(0, 4, "mb-test-loader-" .. H.TIER, D.east, { type = "output" })
    putf(-1, 4, "mb-test-chest").insert({ name = ITEM, count = 500 })
    for k = 1, 3 do
      putf(4 + k, 4, H.BELT, D.east)
    end
    balancer.flush()
    local rec0, id = rec_of(b)
    assert(nm(rec0) == "1:1", "test setup: network " .. nm(rec0))
    local total = H.count_box(box, ITEM)
    balancer.tick_budget = 40
    for k = 1, 3 do
      putf(4, 4 + k, H.BELT, D.south)
    end
    local waited = 0
    local function wait(k)
      after_ticks(1, function()
        waited = waited + 1
        local j = storage.balancer.jobs[id] --[[@as table?]]
        if j and j.b and j.b.i > 1 and j.b.i <= #j.b.ops then
          k()
        else
          assert(waited < 300, "test setup: no placement half done")
          wait(k)
        end
      end)
    end
    wait(function()
      game.merge_forces("mb-test-src", "player")
      each_tick(3000, function() end, function()
        local rec = rec_of(b)
        assert(nm(rec) == "1:2" and not rec.failed, "after a force merge mid-placement: network " .. nm(rec) .. ", failed " .. tostring(rec.failed))
        assert(rec.placed.entities[1].force.name == "player", "the network is owned by " .. rec.placed.entities[1].force.name)
        assert(H.count_box(box, ITEM) == total, "items: " .. H.count_box(box, ITEM) .. " of " .. total)
        done()
      end)
    end)
  end)

  -- I2: a staged placement that fails (test hook) with a tiny budget. The group keeps its old
  -- network, and the flush handler goes away: no flush every tick afterwards.
  test("failed_staged_placement_settles", function()
    async(1500)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 500 })
    H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local total = H.count_box(box, ITEM)
    balancer.tick_budget = 40
    builder.fail_after = 6
    local c = count_flushes()
    H.sink(o, 4, 4, D.south, 3)
    after_ticks(1000, function()
      builder.fail_after = nil
      local rec = rec_of(b)
      H.report("failed staged placement: %d flushes in 1000 ticks, network %s", c.n, nm(rec))
      assert(c.n < 50, c.n .. " flushes in 1000 ticks after a failed staged placement")
      assert(not balancer.pending(storage.balancer), "work still pending")
      assert(nm(rec) == "1:1", "network " .. nm(rec))
      assert(H.count_box(box, ITEM) == total, "items: " .. H.count_box(box, ITEM) .. " of " .. total)
      done()
    end)
  end)

  -- Waits until group `id`'s old network is draining (a few entities emptied), then calls `k`.
  local function when_draining(id, k)
    local waited = 0
    local function wait()
      after_ticks(1, function()
        waited = waited + 1
        local rec = balancer.get(id)
        if rec and rec.draining and #rec.draining > 0 and (rec.draining[1].drain_k or 1) > 3 then
          k()
        else
          assert(waited < 1000, "test setup: no drain under way")
          wait()
        end
      end)
    end
    wait()
  end

  -- The hidden surface is deleted while an old network drains into the new one: every item is
  -- spilled and placed again, nothing lost.
  test("surface_deleted_mid_drain", function()
    async(3000)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 2000 })
    stop(H.sink(o, 4, 4, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, id = rec_of(b)
      balancer.tick_budget = 150
      stop(H.sink(o, 4, 4, D.south, 3))
      when_draining(id, function()
        game.delete_surface("mb-hidden")
        local n0 = 0
        local function settle()
          after_ticks(1, function()
            n0 = n0 + 1
            if balancer.pending(storage.balancer) or not game.get_surface("mb-hidden") then
              assert(n0 < 2000, "not settled")
              settle()
            else
              local n = H.count_box(box, ITEM)
              assert(n == total, "surface deleted mid-drain: " .. n .. " of " .. total)
              done()
            end
          end)
        end
        settle()
      end)
    end)
  end)

  -- The last block goes while one old network drains and a second rebuild is queued: nothing
  -- lost.
  test("removed_mid_drain_with_a_job_queued", function()
    async(3000)
    local o, box = area(12, 12)
    local b = H.block(o, 5, 5, H.TIER)
    H.feed(o, 5, 5, D.west, 3, { stock = 2000 })
    stop(H.sink(o, 5, 5, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, id = rec_of(b)
      balancer.tick_budget = 150
      stop(H.sink(o, 5, 5, D.south, 3))
      when_draining(id, function()
        stop(H.sink(o, 5, 5, D.north, 3)) -- a second rebuild while draining
        after_ticks(3, function()
          b.destroy({ raise_destroy = true })
          each_tick(3000, function(t)
            assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
          end, function()
            assert(H.count_box(box, ITEM) == total, "removed mid-drain: " .. H.count_box(box, ITEM) .. " of " .. total)
            regions_match("after the removal")
            done()
          end)
        end)
      end)
    end)
  end)

  -- Stacked belt items (several items in one belt stack) keep their count through the staged
  -- carry.
  test("stacked_belt_items_drain", function()
    local old = assert(builder.place(assert(network.build(3, 5)), "turbo"))
    for _, e in ipairs(old.entities) do
      if e.type == "linked-belt" then
        for li = 1, 2 do
          e.get_transport_line(li --[[@as defines.transport_line]]).insert_at(0.1, { name = ITEM, count = 4 }, 4)
        end
      end
    end
    local before = builder.contents(old)
    local new, err = builder.rebuild_staged(old, assert(network.build(3, 5)), "turbo")
    new = assert(new, err)
    local after = builder.contents(new)
    assert(serpent.line(before) == serpent.line(after), "contents changed: " .. serpent.line(before) .. " -> " .. serpent.line(after))
    builder.destroy(new)
  end)
  -- Review m6, save and load mid-rebuild, as far as FactorioTest can go (it cannot load a save;
  -- the full check on an MCP instance is in docs/benchmarks.md): mid-placement the handler is
  -- removed, as in a client that has just loaded the save, and only balancer.on_load (which reads
  -- storage) sets it again. The rebuild finishes from storage alone, nothing lost.
  test("rebuild_resumes_from_storage_after_on_load", function()
    async(3000)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 2000 })
    stop(H.sink(o, 4, 4, D.east, 3))
    balancer.flush()
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      local _, id = rec_of(b)
      balancer.tick_budget = 60
      stop(H.sink(o, 4, 4, D.south, 3))
      after_ticks(4, function()
        local r = balancer.get(id)
        assert(storage.balancer.jobs[id] or (r and r.draining and #r.draining > 0), "test setup: no rebuild under way")
        script.on_nth_tick(1, nil)
        local c = count_flushes()
        after_ticks(5, function()
          assert(c.n == 0, "the handler ran while unregistered")
          balancer.on_load()
          each_tick(3000, function(t)
            assert(H.count_box(box, ITEM) == total, "tick " .. t .. ": " .. H.count_box(box, ITEM) .. " of " .. total)
          end, function()
            local rec = rec_of(b)
            assert(c.count() > 0, "on_load did not set the handler again")
            assert(nm(rec) == "1:2" and #(rec.draining or {}) == 0, "network " .. nm(rec))
            regions_match("after the resumed rebuild")
            done()
          end)
        end)
      end)
    end)
  end)
end)
