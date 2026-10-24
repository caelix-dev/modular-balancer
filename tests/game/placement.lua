-- Placement on the hidden surface: scripts/surface.lua (region allocator) and
-- scripts/builder.lua (place / destroy). Plain assert, not luassert.
local network = require("scripts.network")
local surface = require("scripts.surface")
local builder = require("scripts.builder")
local H = require("tests.game.harness")

local TIERS = { "basic", "fast", "express" }
---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["space-age"] then
  TIERS[#TIERS + 1] = "turbo"
end

---@param s LuaSurface
---@param origin {x: number, y: number}
local function count_in(s, origin, w, h)
  return s.count_entities_filtered({ area = { { origin.x, origin.y }, { origin.x + w, origin.y + h } } })
end

describe("placement", function()
  test("place_then_destroy_leaves_nothing", function()
    local s = surface.get()
    assert(game.forces.player.get_surface_hidden(s), "hidden surface is visible to the player force")
    for _, tier in ipairs(TIERS) do
      for _, c in ipairs({ { 1, 1 }, { 2, 3 }, { 3, 5 }, { 8, 3 }, { 1, 5 }, { 5, 1 }, { 16, 16 }, { 8, 3, true }, { 1, 1, true } }) do
        local net = assert(network.build(c[1], c[2], { balance_lanes = c[3] }))
        local w, h = builder.size(net)
        local origin = surface.reserve(w, h)
        local placed = builder.place(net, tier, origin)
        local what = string.format("%s %d:%d%s", tier, c[1], c[2], c[3] and " lanes" or "")
        local lanes = #(net.lane_splitters or {})
        local direct = 0
        for _, ed in ipairs(net.edges) do
          if ed.from.kind == "in" and ed.to.kind == "out" then
            direct = direct + 1
          end
        end
        -- every edge is one linked-belt pair, except the network's own inputs and outputs (one
        -- half each) and pass-throughs (a pair)
        local belts = 2 * #net.edges - c[1] - c[2] + 2 * direct
        assert(#placed.entities == #net.splitters + lanes + belts,
          what .. ": " .. #placed.entities .. " entities, expected " .. (#net.splitters + lanes + belts))
        assert(#placed.inputs == c[1] and #placed.outputs == c[2], what .. ": wrong number of inputs or outputs")
        for i, e in ipairs(placed.inputs) do
          assert(e.linked_belt_type == "output" and e.linked_belt_neighbour == nil, what .. ": input " .. i .. " is not a free output-type linked belt")
        end
        for j, e in ipairs(placed.outputs) do
          assert(e.linked_belt_type == "input" and e.linked_belt_neighbour == nil, what .. ": output " .. j .. " is not a free input-type linked belt")
        end
        for _, e in ipairs(placed.entities) do
          local x, y = e.position.x, e.position.y
          assert(x > origin.x and x < origin.x + w and y > origin.y and y < origin.y + h, what .. ": entity outside the rectangle")
          if e.type == "linked-belt" then
            local outs = e.belt_neighbours.outputs
            assert(#outs <= 1, what .. ": linked belt with more than one belt neighbour")
          end
        end
        assert(count_in(s, origin, w, h) == #placed.entities, what .. ": stray entities in the rectangle")
        local items = builder.destroy(placed)
        assert(#items == 0, what .. ": destroy returned items from an empty network: " .. serpent.line(items))
        assert(count_in(s, origin, w, h) == 0, what .. ": entities left in the rectangle")
        surface.release(origin)
      end
    end
  end)

  -- 10 normal iron plates (and, when the quality "uncommon" exists, as in Space Age, 3 uncommon
  -- iron plates and 2 normal copper plates) on hidden belts come back per item and quality.
  test("destroy_returns_items", function()
    local net = assert(network.build(3, 5))
    local w, h = builder.size(net)
    local origin = surface.reserve(w, h)
    local placed = builder.place(net, "express", origin)
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
    surface.release(origin)
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

  -- No loss and no duplication: a finite stock through a running 3:5 whose outputs are then
  -- blocked, so the network is full of items when it is destroyed.
  test("destroy_returns_all_items_of_a_running_network", function()
    async(1500)
    local rig = H.rig({ n = 3, m = 5, stock = 1000 })
    after_ticks(300, function()
      for _, l in ipairs(rig.sink_loaders) do
        l.disabled_by_script = true
      end
      after_ticks(900, function()
        local inside = 0
        for _, e in ipairs(rig.placed.entities) do
          inside = inside + H.items_on(e)
        end
        local returned = 0
        for _, it in ipairs(H.teardown(rig)) do
          returned = returned + it.count
        end
        local outside = 0
        for i = 1, 3 do
          outside = outside + rig.sources[i][1].get_item_count()
        end
        for _, e in ipairs(rig.visible) do
          outside = outside + H.items_on(e)
        end
        for _, e in ipairs(rig.feeders) do
          outside = outside + H.items_on(e)
        end
        for j = 1, 5 do
          outside = outside + rig.sinks[j].get_item_count() + H.items_on(rig.sink_loaders[j])
        end
        H.report("conservation 3:5: %d inside the network, %d returned, %d outside (of 3000)", inside, returned, outside)
        assert(inside > 0 and returned == inside, "destroy returned " .. returned .. " of " .. inside)
        assert(returned + outside == 3000, "items lost or duplicated: " .. (returned + outside) .. " of 3000")
        done()
      end)
    end)
  end)

  -- Each tier runs at its own belt speed: a 2:3 delivers two full belts of that tier.
  for _, tier in ipairs(TIERS) do
    test("tier_throughput_" .. tier, function()
      async(1800 + 3600 + 300)
      local rig = H.rig({ n = 2, m = 3, tier = tier })
      local rate = (prototypes.entity[H.BELTS[tier]].belt_speed or 0) * 60 * 8
      -- the network's loops fill more slowly on slower belts: 600 ticks at express speed
      local warmup = math.max(600, math.ceil(600 * H.RATE / rate))
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
  end
end)
