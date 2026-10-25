-- Placement on the hidden surface: scripts/surface.lua (region allocator) and
-- scripts/builder.lua (start / advance / destroy, through H.place). Plain assert, not luassert.
local network = require("scripts.network")
local surface = require("scripts.surface")
local builder = require("scripts.builder")
local H = require("tests.game.harness")

local TIERS = { "basic", "fast", "express" }
---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["space-age"] then
  TIERS[#TIERS + 1] = "turbo"
end

-- Entities on the hidden surface inside `placed`'s region.
local function count_in(placed)
  local o, size = placed.origin, placed.size
  return surface.get().count_entities_filtered({ area = { { o.x, o.y }, { o.x + size.w, o.y + size.h } } })
end

---@return integer
local function used_regions()
  local n = 0
  for _ in pairs(storage.regions and storage.regions.used or {}) do
    n = n + 1
  end
  return n
end

describe("placement", function()
  after_each(function()
    builder.fail_after = nil
    H.teardown_all()
  end)

  test("place_then_destroy_leaves_nothing", function()
    local s = surface.get()
    assert(game.forces.player.get_surface_hidden(s), "hidden surface is visible to the player force")
    for _, tier in ipairs(TIERS) do
      for _, c in ipairs({ { 1, 1 }, { 2, 3 }, { 3, 5 }, { 8, 3 }, { 1, 5 }, { 5, 1 }, { 9, 1 }, { 16, 16 }, { 8, 3, true }, { 1, 1, true } }) do
        local net = assert(network.build(c[1], c[2], { balance_lanes = c[3] }))
        local placed, err = H.place(net, tier)
        local what = string.format("%s %d:%d%s", tier, c[1], c[2], c[3] and " lanes" or "")
        assert(placed, what .. ": place failed: " .. tostring(err))
        assert(placed.tier == tier and placed.force == "player" and placed.buffer and placed.buffer.valid, what .. ": Placed fields")
        local lanes = #(net.lane_splitters or {})
        local direct = 0
        for _, ed in ipairs(net.edges) do
          if ed.from.kind == "in" and ed.to.kind == "out" then
            direct = direct + 1
          end
        end
        -- every edge is one linked-belt pair, except the network's own inputs and outputs (one
        -- half each) and pass-throughs (a pair); the buffer strip adds 5 entities
        local belts = 2 * #net.edges - c[1] - c[2] + 2 * direct
        local expected = #net.splitters + #net.priority + lanes + belts + 5
        assert(#placed.entities == expected, what .. ": " .. #placed.entities .. " entities, expected " .. expected)
        assert(#placed.inputs == c[1] and #placed.outputs == c[2], what .. ": wrong number of inputs or outputs")
        for i, e in ipairs(placed.inputs) do
          assert(e.linked_belt_type == "output" and e.linked_belt_neighbour == nil, what .. ": input " .. i .. " is not a free output-type linked belt")
        end
        for j, e in ipairs(placed.outputs) do
          assert(e.linked_belt_type == "input" and e.linked_belt_neighbour == nil, what .. ": output " .. j .. " is not a free input-type linked belt")
        end
        local prioritized = 0
        local o, size = placed.origin, placed.size
        for _, e in ipairs(placed.entities) do
          local x, y = e.position.x, e.position.y
          assert(x > o.x and x < o.x + size.w and y > o.y and y < o.y + size.h, what .. ": entity outside the rectangle")
          if e.type == "linked-belt" then
            assert(#e.belt_neighbours.outputs <= 1, what .. ": linked belt with more than one belt neighbour")
          elseif e.type == "splitter" and e.splitter_output_priority ~= "none" then
            prioritized = prioritized + 1
          end
        end
        -- priority nodes, plain splitters with exactly one connected output, and the buffer's
        -- merge splitter
        local outs, dead_end = {}, 0
        for _, ed in ipairs(net.edges) do
          if ed.from.kind == "splitter" then
            outs[ed.from.id] = (outs[ed.from.id] or 0) + 1
          end
        end
        for _, sp in ipairs(net.splitters) do
          if outs[sp.id] == 1 then
            dead_end = dead_end + 1
          end
        end
        local want = #net.priority + dead_end + 1
        assert(prioritized == want, what .. ": " .. prioritized .. " splitters with output priority, expected " .. want)
        assert(count_in(placed) == #placed.entities, what .. ": stray entities in the rectangle")
        local region = { origin = placed.origin, size = placed.size }
        local regions = used_regions()
        local items = builder.destroy(placed)
        assert(#items == 0, what .. ": destroy returned items from an empty network: " .. serpent.line(items))
        assert(count_in(region) == 0, what .. ": entities left in the rectangle")
        assert(used_regions() == regions - 1, what .. ": destroy did not release the region")
      end
    end
  end)

  -- A failure while creating entity k leaves nothing behind: no entity, and the region is free.
  test("place_is_atomic", function()
    local s = surface.get()
    local net = assert(network.build(3, 5))
    for _, k in ipairs({ 1, 2, 40, 120 }) do
      local entities, regions = s.count_entities_filtered({}), used_regions()
      builder.fail_after = k
      local placed, err = H.place(net, "express")
      builder.fail_after = nil
      assert(placed == nil and err and err:find("test hook"), "place did not fail at entity " .. k .. ": " .. tostring(err))
      assert(s.count_entities_filtered({}) == entities, "entities left after a failure at entity " .. k)
      assert(used_regions() == regions, "region not released after a failure at entity " .. k)
    end
    -- and the next place works
    local placed = assert(H.place(net, "express"))
    builder.destroy(placed)
  end)

  -- 10 normal iron plates (and, when the quality "uncommon" exists, as in Space Age, 3 uncommon
  -- iron plates and 2 normal copper plates) on hidden belts come back per item and quality.
  test("destroy_returns_items", function()
    local placed = assert(H.place(assert(network.build(3, 5)), "express"))
    local want = { { name = "iron-plate", quality = "normal", count = 10 } }
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.quality["uncommon"] then
      want = {
        { name = "copper-plate", quality = "normal", count = 2 },
        { name = "iron-plate", quality = "normal", count = 10 },
        { name = "iron-plate", quality = "uncommon", count = 3 },
      }
    end
    local slots = {}
    for _, e in ipairs(placed.entities) do
      if e.type == "linked-belt" then
        for _, li in ipairs(H.LINES) do
          slots[#slots + 1] = e.get_transport_line(li)
        end
      end
    end
    local k = 0
    for _, wnt in ipairs(want) do
      for _ = 1, wnt.count do
        k = k + 1
        assert(slots[k] and slots[k].insert_at(0.1, { name = wnt.name, quality = wnt.quality, count = 1 }),
          "could not put " .. wnt.name .. " on hidden belt " .. k)
      end
    end
    local items = builder.destroy(placed)
    assert(#items == #want, "destroy returned " .. serpent.line(items))
    for i, wnt in ipairs(want) do
      local got = items[i]
      assert(got and got.name == wnt.name and got.quality == wnt.quality and got.count == wnt.count,
        "entry " .. i .. ": destroy returned " .. serpent.line(items) .. ", expected " .. serpent.line(want))
    end
  end)

  test("regions_do_not_overlap", function()
    local regions = {}
    for i = 1, 50 do
      local w, h = 4 + (i * 37) % 70, 3 + (i * 53) % 90
      local o = surface.reserve(w, h)
      regions[i] = { x = o.x, y = o.y, w = w, h = h, origin = o }
    end
    local function disjoint(a, b)
      return a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y
    end
    for i = 1, 50 do
      for j = i + 1, 50 do
        assert(disjoint(regions[i], regions[j]), "regions " .. i .. " and " .. j .. " overlap: "
          .. serpent.line(regions[i]) .. " " .. serpent.line(regions[j]))
      end
    end
    -- released regions are reused, and a reused region still does not overlap the others
    surface.release(regions[7].origin)
    local again = surface.reserve(regions[7].w, regions[7].h)
    assert(again.x == regions[7].x and again.y == regions[7].y, "released region was not reused")
    for i = 1, 50 do
      surface.release(regions[i].origin)
    end
  end)

  -- The hidden prototypes are built in data-final-fixes from the final belt speeds (final
  -- review M3). With the test mod mb-test-speed (tests/mods/mb-test-speed, an MCP check: see
  -- docs/feasibility.md), the express belt is faster than vanilla and the hidden express
  -- entities follow it.
  test("tier_speed_follows_final_prototypes", function()
    for _, tier in ipairs(TIERS) do
      local belt = prototypes.entity[H.BELTS[tier]].belt_speed
      for _, kind in ipairs({ "splitter", "linked-belt", "lane-splitter", "loader" }) do
        local p = prototypes.entity["mb-hidden-" .. kind .. "-" .. tier]
        assert(p and p.belt_speed == belt, string.format("mb-hidden-%s-%s: speed %s, belt %s", kind, tier,
          tostring(p and p.belt_speed), tostring(belt)))
      end
    end
    -- the runtime check control.lua runs on init and configuration change (review M6)
    local mismatches = builder.speed_mismatches()
    assert(#mismatches == 0, "speed mismatches: " .. serpent.line(mismatches))
    ---@diagnostic disable-next-line: unnecessary-if
    if script.active_mods["mb-test-speed"] then
      local express = prototypes.entity["express-transport-belt"].belt_speed
      assert(express ~= 0.09375, "mb-test-speed did not change the express belt speed")
      H.report("tier_speed_follows_final_prototypes with mb-test-speed: express belt %.6f, hidden express linked belt %.6f",
        express, prototypes.entity["mb-hidden-linked-belt-express"].belt_speed)
    end
  end)

  -- No loss and no duplication: a finite stock (1 000 per input) through a running network whose
  -- outputs are then blocked, so it is full of items when it is destroyed. 8:3 (N > M) has
  -- splitters with an unconnected output, closed by output priority plus the mb-hidden-never
  -- filter (scripts/builder.lua; this supersedes Plan 1's Ruling 5); the test checks that
  -- those splitters hold items before the teardown and that destroy returns them.
  ---@type {[1]: integer, [2]: integer}[]
  local CONSERVATION = { { 3, 5 }, { 8, 3 } }
  for _, r in ipairs(CONSERVATION) do
    local n, m = r[1], r[2]
    test("destroy_returns_all_items_of_a_running_network_" .. n .. "_" .. m, function()
      async(2100)
      local rig = H.rig({ n = n, m = m, stock = 1000 })
      -- splitters with an output port no edge leaves from (placed.entities starts with the
      -- plain splitters, in net.splitters order)
      local used = {}
      for _, ed in ipairs(rig.net.edges) do
        if ed.from.kind == "splitter" then
          used[ed.from.id .. ":" .. ed.from.port] = true
        end
      end
      local dead = {}
      for k, sp in ipairs(rig.net.splitters) do
        if not used[sp.id .. ":1"] or not used[sp.id .. ":2"] then
          dead[#dead + 1] = rig.placed.entities[k]
        end
      end
      after_ticks(300, function()
        for _, l in ipairs(rig.sink_loaders) do
          l.disabled_by_script = true
        end
        after_ticks(1500, function()
          local inside, on_dead = H.network_items(rig), 0
          for _, e in ipairs(dead) do
            assert(e.type == "splitter", "dead-end lookup did not find a splitter")
            on_dead = on_dead + H.items_on(e)
          end
          local outside = 0
          for i = 1, n do
            outside = outside + rig.sources[i][1].get_item_count()
          end
          for _, group in ipairs({ rig.visible, rig.feeders, rig.sink_loaders }) do
            for _, e in ipairs(group) do
              outside = outside + H.items_on(e)
            end
          end
          for j = 1, m do
            outside = outside + rig.sinks[j].get_item_count()
          end
          local returned = 0
          for _, it in ipairs(H.teardown(rig)) do
            returned = returned + it.count
          end
          local stock = n * 1000
          H.report("conservation %d:%d: %d inside the network (%d on %d dead-end splitters), %d returned, %d outside (of %d)",
            n, m, inside, on_dead, #dead, returned, outside, stock)
          -- the dead-end splitters hold items on their input and live output lines when backed
          -- up (counted, and returned by destroy); that nothing stays on a closed dead end after
          -- a drain is rebuild.lua's shrink_keeps_every_item
          if n > m then
            assert(#dead > 0 and on_dead > 0, "8:3: no backed-up dead-end splitter (" .. #dead .. ")")
          end
          assert(inside > 0 and returned == inside, "destroy returned " .. returned .. " of " .. inside)
          assert(returned + outside == stock, "items lost or duplicated: " .. (returned + outside) .. " of " .. stock)
          done()
        end)
      end)
    end)
  end

  -- Each tier runs at its own belt speed: a 2:3 delivers two full belts of that tier.
  for _, tier in ipairs(TIERS) do
    local rate = (prototypes.entity[H.BELTS[tier]].belt_speed or 0) * 60 * 8
    -- recirculating networks settle in about 3 000 ticks at express speed, slower on slower belts
    local warmup = math.max(3000, math.ceil(3000 * H.RATE / rate))
    test("tier_throughput_" .. tier, function()
      async(warmup + 3600 + 300)
      local rig = H.rig({ n = 2, m = 3, tier = tier })
      H.measure(function()
        local c = {}
        for j = 1, 3 do
          c[j] = rig.sinks[j].get_item_count()
        end
        return c
      end, warmup, 3600, function(rates)
        local total = rates[1] + rates[2] + rates[3]
        H.report("tier %s 2:3: outputs %.3f %.3f %.3f, total %.3f (2 belts = %.3f)", tier, rates[1], rates[2], rates[3], total, 2 * rate)
        assert(math.abs(total - 2 * rate) <= 2 * rate * 0.01, tier .. ": total " .. total .. ", expected " .. 2 * rate)
        H.assert_equal(rates, tier .. " output")
        done()
      end)
    end)

    -- Final review M8: the lane splitters of every tier carry items at that tier's speed. A 1:1
    -- with balance_lanes and only the left lane fed delivers half a belt, split over both lanes.
    test("lane_splitters_carry_items_per_tier_" .. tier, function()
      async(warmup + 3600 + 300)
      local rig = H.rig({ n = 1, m = 1, tier = tier, balance_lanes = true, feed = { "left" } })
      local counts = H.lane_counter(rig)
      H.measure(function()
        return { H.sum(counts[1][1]), H.sum(counts[1][2]) }
      end, warmup, 3600, function(rates)
        H.report("lane splitter %s 1:1 (left lane only): left %.3f right %.3f, total %.3f (half a belt = %.3f)",
          tier, rates[1], rates[2], rates[1] + rates[2], rate / 2)
        assert(math.abs(rates[1] + rates[2] - rate / 2) <= rate / 2 * 0.01, tier .. ": total " .. (rates[1] + rates[2]))
        H.assert_equal(rates, tier .. " lane")
        done()
      end)
    end)
  end
end)
