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
---@return { n: integer }
local function count_flushes()
  local c = { n = 0 }
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
      after_ticks(3, function()
        local job = storage.balancer.jobs[id]
        assert(job and job.b and job.b.i > 1 and job.b.i <= #job.b.ops, "test setup: no placement half done")
        local first = job.b.placed
        stop(H.sink(o, 4, 4, D.north, 3))
        local restarted = false
        each_tick(4000, function(t)
          local j = storage.balancer.jobs[id]
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
      -- the north input goes: its last tile is an edge; mined with its items into a chest
      local edge = assert(H.at(o, 5, 4, "linked-belt"), "no north edge")
      local keep = H.ce(game.surfaces.nauvis, { name = "mb-test-chest", position = { o.x + 11, o.y + 11 } })
      assert(edge.mine({ inventory = keep.get_inventory(defines.inventory.chest), raise_destroyed = true }), "edge not mined")
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
        builder.max_buffer_slots = 65535
        balancer.mark({ id })
        balancer.flush()
        local rec2 = rec_of(b)
        assert(#(rec2.draining or {}) == 0, "the drain did not resume")
        assert(H.count_box(box) == total, "after the resumed drain: " .. H.count_box(box) .. " of " .. total)
        regions_match("after the resumed drain")
        done()
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
    src.insert({ name = ITEM, count = 400 })
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
    local function count()
      local n = 0
      for _, e in ipairs(s.find_entities_filtered({ area = { { 10, -6 }, { 25, 7 } } })) do
        if e.type == "container" then
          n = n + e.get_item_count(ITEM)
        elseif e.type == "item-entity" then
          n = n + (e.stack.name == ITEM and e.stack.count or 0)
        elseif e.get_max_transport_line_index then
          local ok, k = pcall(e.get_max_transport_line_index)
          for i = 1, ok and k or 0 do
            n = n + e.get_transport_line(i).get_item_count(ITEM)
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
      assert(count() == 400, "on the platform: " .. count())
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
        blk.destroy({ raise_destroy = true })
        balancer.flush()
        local now = 0
        for _, ent in ipairs(s.find_entities_filtered({ area = { { 10, -6 }, { 25, 7 } } })) do
          if ent.type == "container" or ent.type == "item-entity" or ent.type == "transport-belt" or ent.type == "loader-1x1" then
            if ent.type == "item-entity" then
              now = now + (ent.stack.name == ITEM and ent.stack.count or 0)
            elseif ent.type == "container" then
              now = now + ent.get_item_count(ITEM)
            else
              for i = 1, ent.get_max_transport_line_index() do
                now = now + ent.get_transport_line(i).get_item_count(ITEM)
              end
            end
          end
        end
        local to_hub = hub.get_item_count(ITEM) - hub0
        assert(to_hub >= inside, "the hub got " .. to_hub .. " of the network's " .. inside)
        assert(now + to_hub == left, "after the removal: " .. now .. " + " .. to_hub .. " in the hub, expected " .. left)
        p.destroy()
        done()
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
end)
