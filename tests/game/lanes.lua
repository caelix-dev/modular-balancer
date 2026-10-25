-- Per-balancer settings (Plan 3 Task 3, scripts/gui.lua): balance lanes and redistribute unused
-- shares. Toggling either on a running balancer rebuilds it with its items, the setting travels
-- with settings paste and blueprints, and a merge keeps the larger group's settings.
-- fdev test is headless and has no player, so the GUI's checkbox is driven through gui.set (what
-- the checkbox handler calls), settings paste through the mod's on_entity_settings_pasted
-- handler, and on_player_setup_blueprint as in tests/game/lifecycle.lua (with the mapping that
-- LuaItemCommon::create_blueprint returns). Express belts (45 items/s). Plain assert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")
local events = require("scripts.events")
local lifecycle = require("scripts.lifecycle")
local gui = require("scripts.gui")

local D = defines.direction
local RATE = H.RATE
local ITEM = "iron-plate"

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

---@param block LuaEntity
---@return mb.Balancer rec, integer id
local function rec_of(block)
  local id = assert(groups.of(block.unit_number), "block without a group")
  local rec = assert(balancer.get(id), "no balancer for group " .. tostring(id))
  return rec, id
end

local function near(v, want, what)
  assert(math.abs(v - want) <= want * 0.01, string.format("%s: %.3f, expected %.3f within 1 %%", what, v, want))
end

-- Hidden entities of type `t` in a placed network.
---@param rec mb.Balancer
---@param t string
---@return integer
local function count_type(rec, t)
  local n = 0
  for _, e in ipairs(assert(rec.placed).entities) do
    if e.valid and e.type == t then
      n = n + 1
    end
  end
  return n
end

local function fmt(list)
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = string.format("%.2f", v)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- An input into the west side of the block at (bx, by) that carries items on its left lane only:
-- 4 belts pointing east, and a feeder column (chest, loader, belt) side-loading the second belt
-- from the north.
local function left_feed(o, bx, by, stock)
  for k = 1, 4 do
    H.put(o, bx - k, by, H.BELT, D.east)
  end
  local x = bx - 3
  H.put(o, x, by - 1, H.BELT, D.south)
  H.put(o, x, by - 2, "mb-test-loader-" .. H.TIER, D.south, { type = "output" })
  local chest = H.put(o, x, by - 3, "mb-test-chest")
  chest.insert({ name = ITEM, count = stock })
end

-- Every tick, counts and clears the items on each lane of each belt in `belts`.
-- Returns counts[j] = { left, right }.
local function lane_counter(belts)
  local counts = {}
  for j = 1, #belts do
    counts[j] = { 0, 0 }
  end
  on_tick(function()
    for j, b in ipairs(belts) do
      for li = 1, 2 do
        local line = b.get_transport_line(H.LINES[li])
        local n = line.get_item_count()
        if n > 0 then
          counts[j][li] = counts[j][li] + n
          line.clear()
        end
      end
    end
  end)
  return counts
end

-- A fake LuaLazyLoadedValue for on_player_setup_blueprint's mapping.
local function lazy(v)
  return { valid = true, get = function() return v end }
end

-- A blueprint in a script inventory of `bbox`, set up through the mod's handler as a player's
-- selection would be. Returns the stack and the inventory (destroy it when done).
local function blueprint_of(bbox)
  local inv = game.create_inventory(1)
  inv.insert({ name = "blueprint" })
  local bp = inv[1]
  local map = bp.create_blueprint({ surface = game.surfaces.nauvis, force = "player", area = bbox })
  lifecycle.on_player_setup_blueprint({ player_index = nil, stack = bp, mapping = lazy(map) })
  return bp, inv
end

-- Pastes `bp` at `position` and revives its ghosts (raise_revive, as robots would).
local function paste(bp, position, box)
  local s = game.surfaces.nauvis
  bp.build_blueprint({ surface = s, force = "player", position = position, build_mode = defines.build_mode.forced, raise_built = true })
  for _, g in ipairs(s.find_entities_filtered({ area = box, type = "entity-ghost" })) do
    if g.valid then
      g.revive({ raise_revive = true })
    end
  end
end

---@return LuaEntity[]
local function blocks_in(box)
  local list = {}
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "simple-entity-with-owner" })) do
    if groups.tier_of(e.name) then
      list[#list + 1] = e
    end
  end
  return list
end

local function same(s, lanes, recirc, what)
  assert(s.lanes == lanes and s.recirc == recirc,
    string.format("%s: lanes %s, recirc %s; expected %s, %s", what, tostring(s.lanes), tostring(s.recirc), tostring(lanes), tostring(recirc)))
end

describe("lanes", function()
  after_each(function()
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- Review Focus 3. A running 2:3 fed on its left input lanes only. Turning lane balancing on
  -- rebuilds it with every item kept; then both lanes of every output carry the same (7.5/s each:
  -- two half belts in, spread over six lanes).
  test("toggle_lanes_on_full_balancer", function()
    async(900 + 600 + 600 + 3600 + 300)
    local o, box = area(14, 12)
    local blocks = {}
    for y = 0, 4 do
      blocks[#blocks + 1] = H.block(o, 6, y + 2, H.TIER)
    end
    local STOCK = 4000
    left_feed(o, 6, 2, STOCK)
    left_feed(o, 6, 6, STOCK)
    local sinks = {}
    for _, y in ipairs({ 2, 4, 6 }) do
      sinks[#sinks + 1] = H.sink(o, 6, y, D.east, 3)
    end
    balancer.flush()
    local rec, gid = rec_of(blocks[1])
    assert(rec.n == 2 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:3")
    assert(rec.lanes ~= true and count_type(rec, "lane-splitter") == 0, "test setup: lanes balanced already")
    after_ticks(900, function()
      local total = H.count_box(box, ITEM)
      assert(total == 2 * STOCK, "before the toggle: " .. total .. " of " .. 2 * STOCK)
      assert(H.network_of(gid) > 0, "test setup: the network holds nothing")
      assert(gui.set(gid, { lanes = true }), "the setting did not change")
      same(groups.settings(gid), true, true, "after the toggle")
      balancer.flush()
      local r2 = rec_of(blocks[1])
      assert(r2.lanes == true, "the network was not rebuilt with lanes")
      assert(count_type(r2, "lane-splitter") == 2, count_type(r2, "lane-splitter") .. " lane splitters, expected 2")
      local after = H.count_box(box, ITEM)
      H.report("toggle_lanes: %d items before, %d after the rebuild", total, after)
      assert(after == total, "after the rebuild: " .. after .. " of " .. total)
      after_ticks(600, function()
        assert(H.count_box(box, ITEM) == total, "600 ticks after: " .. H.count_box(box, ITEM) .. " of " .. total)
        local last = {}
        for j, r in ipairs(sinks) do
          last[j] = r.belts[3]
        end
        local counts = lane_counter(last)
        H.measure(function()
          local c = {}
          for j = 1, #counts do
            c[#c + 1] = counts[j][1]
            c[#c + 1] = counts[j][2]
          end
          return c
        end, 600, 3600, function(rates)
          H.report("toggle_lanes: lanes (left right per output) %s items/s, total %.3f", fmt(rates), H.sum(rates))
          H.assert_equal(rates, "lane")
          near(H.sum(rates), RATE, "total")
          done()
        end)
      end)
    end)
  end)

  -- A running 2:3 with full inputs. Turning recirculation off rebuilds the plain network (smaller)
  -- with every item kept, and with all outputs free it is still exact; turning it on again keeps
  -- every item too.
  test("toggle_recirc_on_full_balancer", function()
    async(900 + 600 + 3600 + 600 + 300)
    local o, box = area(12, 8)
    local blocks = {}
    for y = 0, 2 do
      blocks[#blocks + 1] = H.block(o, 5, y + 2, H.TIER)
    end
    local STOCK = 6000
    H.feed(o, 5, 2, D.west, 3, { stock = STOCK })
    H.feed(o, 5, 4, D.west, 3, { stock = STOCK })
    local sinks = {}
    for y = 2, 4 do
      sinks[#sinks + 1] = H.sink(o, 5, y, D.east, 3)
    end
    balancer.flush()
    local rec, gid = rec_of(blocks[1])
    assert(rec.n == 2 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:3")
    local big = #assert(rec.placed).entities
    after_ticks(900, function()
      local total = H.count_box(box, ITEM)
      assert(total == 2 * STOCK, "before the toggle: " .. total .. " of " .. 2 * STOCK)
      assert(gui.set(gid, { recirc = false }), "the setting did not change")
      same(groups.settings(gid), false, false, "after the toggle")
      balancer.flush()
      local r2 = rec_of(blocks[1])
      assert(r2.recirc == false, "the network was not rebuilt without recirculation")
      local small = #assert(r2.placed).entities
      assert(small < big, "plain network " .. small .. " entities, recirculating " .. big)
      local after = H.count_box(box, ITEM)
      H.report("toggle_recirc: %d entities with recirculation, %d without; %d items before, %d after", big, small, total, after)
      assert(after == total, "after the rebuild: " .. after .. " of " .. total)
      H.measure(function()
        local c = {}
        for j, r in ipairs(sinks) do
          c[j] = r.chest.get_item_count()
        end
        return c
      end, 600, 3600, function(rates)
        H.report("toggle_recirc: plain outputs %s items/s", fmt(rates))
        for j, v in ipairs(rates) do
          near(v, 2 * RATE / 3, "output " .. j)
        end
        local before = H.count_box(box, ITEM)
        assert(gui.set(gid, { recirc = true }), "the setting did not change back")
        balancer.flush()
        local r3 = rec_of(blocks[1])
        assert(r3.recirc == true and #assert(r3.placed).entities > small, "not rebuilt with recirculation")
        assert(H.count_box(box, ITEM) == before, "after turning it on again: " .. H.count_box(box, ITEM) .. " of " .. before)
        after_ticks(600, function()
          assert(H.count_box(box, ITEM) == before, "600 ticks later: " .. H.count_box(box, ITEM) .. " of " .. before)
          done()
        end)
      end)
    end)
  end)

  -- Review Focus 4. Settings paste between blocks copies both settings to the destination's
  -- balancer (and rebuilds it); a blueprint of a balancer with lanes on and recirculation off
  -- carries both as block tags, and the pasted balancer has them.
  test("settings_paste_and_blueprint_keep_lanes", function()
    async(200)
    local o, box = area(16, 8)
    local a1 = H.block(o, 3, 3, H.TIER)
    H.block(o, 3, 4, H.TIER)
    H.feed(o, 3, 3, D.west, 2, { stock = 200 })
    H.sink(o, 3, 3, D.east, 2)
    H.sink(o, 3, 4, D.east, 2)
    local b = H.block(o, 11, 3, H.TIER)
    H.feed(o, 11, 3, D.west, 2, { stock = 200 })
    H.sink(o, 11, 3, D.east, 2)
    H.sink(o, 11, 3, D.south, 2)
    balancer.flush()
    local ra, ga = rec_of(a1)
    local rb, gb = rec_of(b)
    assert(ga ~= gb and ra.placed and rb.placed, "test setup: two running balancers expected")
    same(groups.settings(gb), false, true, "defaults")
    gui.set(ga, { lanes = true, recirc = false })
    balancer.flush()
    local ra2 = rec_of(a1)
    assert(ra2.lanes == true and ra2.recirc == false, "source not rebuilt with its settings")

    -- settings paste (shift right-click, shift left-click)
    events.on_settings_pasted({ source = a1, destination = b, player_index = nil })
    same(groups.settings(gb), true, false, "after the paste")
    balancer.flush()
    local rb2 = rec_of(b)
    assert(rb2.lanes == true and rb2.recirc == false and count_type(rb2, "lane-splitter") == 1, "destination not rebuilt with the pasted settings")
    same(groups.settings(ga), true, false, "the source after the paste")

    -- blueprint of the two-block balancer
    local bp, inv = blueprint_of({ { o.x - 0.5, o.y + 1.5 }, { o.x + 6.5, o.y + 5.5 } })
    local tagged = 0
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      if groups.tier_of(be.name) then
        local t = be.tags or {}
        assert(t.mb_lanes == true and t.mb_recirc == false, "block tags " .. serpent.line(be.tags))
        tagged = tagged + 1
      end
      assert(be.name:sub(1, 8) ~= "mb-edge-", "the blueprint holds an edge")
    end
    assert(tagged == 2, tagged .. " blocks tagged, expected 2")
    -- a blueprint of a default balancer carries the defaults
    gui.set(gb, { lanes = false, recirc = true })
    local bp2, inv2 = blueprint_of({ { o.x + 8.5, o.y + 1.5 }, { o.x + 14.5, o.y + 6.5 } })

    local o2, box2 = area(8, 8)
    paste(bp, { o2.x + 3, o2.y + 4 }, box2)
    local pasted = blocks_in(box2)
    assert(#pasted == 2, #pasted .. " blocks pasted, expected 2")
    local gp = groups.of(pasted[1].unit_number)
    assert(gp and gp == groups.of(pasted[2].unit_number), "the pasted blocks are not one group")
    same(groups.settings(gp), true, false, "pasted balancer")
    balancer.flush()
    local rp = rec_of(pasted[1])
    assert(rp.placed and rp.lanes == true and rp.recirc == false, "pasted balancer not built with its settings")

    local o3, box3 = area(8, 8)
    paste(bp2, { o3.x + 3, o3.y + 4 }, box3)
    local p3 = assert(blocks_in(box3)[1], "default blueprint: no block")
    same(groups.settings(groups.of(p3.unit_number)), false, true, "pasted default balancer")
    inv.destroy()
    inv2.destroy()
    -- nothing was lost in the source area (both balancers kept their items through the rebuilds)
    after_ticks(120, function()
      assert(H.count_box(box, ITEM) == 400, "source area: " .. H.count_box(box, ITEM) .. " of 400")
      done()
    end)
  end)

  -- A merge keeps the larger group's settings, in both directions, and a split gives every part
  -- the old group's settings.
  test("merge_takes_larger_groups_setting", function()
    local o, box = area(14, 10)
    -- larger group (3 blocks) with lanes on and recirculation off, smaller (1 block) with defaults
    local big = H.block(o, 2, 2, H.TIER)
    H.block(o, 3, 2, H.TIER)
    H.block(o, 4, 2, H.TIER)
    local small = H.block(o, 6, 2, H.TIER)
    H.feed(o, 2, 2, D.west, 2, { stock = 100 })
    H.sink(o, 6, 2, D.east, 2)
    H.sink(o, 3, 2, D.south, 2)
    balancer.flush()
    local gbig = groups.of(big.unit_number)
    gui.set(gbig, { lanes = true, recirc = false })
    balancer.flush()
    same(groups.settings(groups.of(small.unit_number)), false, true, "small group")
    local mid = H.block(o, 5, 2, H.TIER)
    balancer.flush()
    local g = groups.of(small.unit_number)
    assert(g == groups.of(big.unit_number), "the blocks did not merge")
    same(groups.settings(g), true, false, "merged (larger had lanes on, recirculation off)")
    local rec = rec_of(big)
    assert(rec.placed and rec.lanes == true and rec.recirc == false, "merged network not built with the larger group's settings")

    -- split: both parts keep the settings
    mid.destroy({ raise_destroy = true })
    balancer.flush()
    local g1, g2 = groups.of(big.unit_number), groups.of(small.unit_number)
    assert(g1 ~= g2, "the row did not split")
    same(groups.settings(g1), true, false, "split part 1")
    same(groups.settings(g2), true, false, "split part 2")

    -- the other direction: the larger group has the defaults, the smaller lanes on and
    -- recirculation off
    gui.set(g1, { lanes = false, recirc = true })
    local lone = H.block(o, 2, 7, H.TIER)
    H.block(o, 3, 7, H.TIER)
    H.block(o, 4, 7, H.TIER)
    local one = H.block(o, 6, 7, H.TIER)
    local gl, go = groups.of(lone.unit_number), groups.of(one.unit_number)
    gui.set(go, { lanes = true, recirc = false })
    same(groups.settings(gl), false, true, "larger group (defaults)")
    H.block(o, 5, 7, H.TIER)
    local gm = groups.of(one.unit_number)
    assert(gm == groups.of(lone.unit_number), "the second row did not merge")
    same(groups.settings(gm), false, true, "merged (larger had the defaults)")
    balancer.flush()
    local total = H.count_box(box, ITEM)
    assert(total == 100, "items: " .. total .. " of 100")
  end)
end)
