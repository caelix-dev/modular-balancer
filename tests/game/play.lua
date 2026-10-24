-- Live balancing end to end (scripts/balancer.lua, scripts/io.lua): blocks, belts, loaders,
-- chests and inserters are all built with raise_built, as a player would, and the balancer
-- flushes as the next tick would. Each balance test measures 3 600 ticks after a 3 000-tick
-- warm-up and checks equality within 1 %. Express belts (45 items/s) in both presets.
-- Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")

local D = defines.direction
local WARMUP, WINDOW = 3000, 3600
local RATE = H.RATE

local default_notify = balancer.notify

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

local function rec_of(block)
  local id = groups.of(block.unit_number)
  return id, assert(balancer.get(id), "no balancer for group " .. tostring(id))
end

-- Asserts |v - want| <= 1 % of want.
local function near(v, want, what)
  assert(math.abs(v - want) <= want * 0.01, string.format("%s: %.3f, expected %.3f within 1 %%", what, v, want))
end

local function chests(list)
  return function()
    local c = {}
    for i, r in ipairs(list) do
      c[i] = r.chest.get_item_count()
    end
    return c
  end
end

local function drawn(list)
  return function()
    local c = {}
    for i, r in ipairs(list) do
      c[i] = r.stock - r.chest.get_item_count()
    end
    return c
  end
end

describe("play", function()
  -- bulk inserters at full hand size, as after the research (like the F3 spike)
  local saved_bonus
  before_each(function()
    saved_bonus = game.forces.player.bulk_inserter_capacity_bonus
    game.forces.player.bulk_inserter_capacity_bonus = 11
  end)
  after_each(function()
    game.forces.player.bulk_inserter_capacity_bonus = saved_bonus
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
    balancer.notify = default_notify
  end)

  -- The spec's 1x8 example: a column of 8 express blocks, 8 belts in on the west face and 3 out
  -- on the east face. Outputs equal at a full belt each; the 8 inputs drawn equally under
  -- backpressure (135 / 8 each).
  test("row_8_in_3_out_balances", function()
    async(WARMUP + WINDOW + 300)
    local o = area(14, 10)
    local blocks, ins, outs = {}, {}, {}
    for y = 0, 7 do
      blocks[#blocks + 1] = H.block(o, 5, y, H.TIER)
    end
    for y = 0, 7 do
      ins[#ins + 1] = H.feed(o, 5, y, D.west, 3)
    end
    for _, y in ipairs({ 1, 4, 6 }) do
      outs[#outs + 1] = H.sink(o, 5, y, D.east, 3)
    end
    balancer.flush()
    local _, rec = rec_of(blocks[1])
    assert(rec.n == 8 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 8:3")
    local ein, eout = H.at(o, 4, 0, "linked-belt"), H.at(o, 6, 1, "linked-belt")
    assert(ein and ein.name == "mb-edge-in-" .. H.BELT, "west tile not an input edge")
    assert(eout and eout.name == "mb-edge-out-" .. H.BELT, "east tile not an output edge")
    local cin, cout = drawn(ins), chests(outs)
    H.measure(function()
      local a, b = cout(), cin()
      for _, v in ipairs(b) do
        a[#a + 1] = v
      end
      return a
    end, WARMUP, WINDOW, function(rates)
      local out, draw = { rates[1], rates[2], rates[3] }, {}
      for i = 4, #rates do
        draw[#draw + 1] = rates[i]
      end
      H.report("row_8_in_3_out: outputs %s, draw %s", serpent.line(out), serpent.line(draw))
      H.assert_equal(out, "output")
      for j, v in ipairs(out) do
        near(v, RATE, "output " .. j)
      end
      local mean = H.assert_equal(draw, "input draw")
      near(mean * 8, 3 * RATE, "total draw")
      done()
    end)
  end)

  -- The user's drawing (spec Update 2): a row of 5 blocks with a 6th bent down at the right end,
  -- 2 inputs from above, 6 outputs (below the row, below the bent block, right of the row's end).
  test("user_l_shape_2_in_6_out", function()
    async(WARMUP + WINDOW + 300)
    local o = area(12, 12)
    local first
    for x = 2, 6 do
      local b = H.block(o, x, 4, H.TIER)
      first = first or b
    end
    H.block(o, 6, 5, H.TIER)
    local ins = { H.feed(o, 2, 4, D.north, 3), H.feed(o, 3, 4, D.north, 3) }
    local outs = {}
    for x = 2, 5 do
      outs[#outs + 1] = H.sink(o, x, 4, D.south, 3)
    end
    outs[#outs + 1] = H.sink(o, 6, 5, D.south, 3)
    outs[#outs + 1] = H.sink(o, 6, 4, D.east, 3)
    balancer.flush()
    local _, rec = rec_of(first)
    assert(rec.n == 2 and rec.m == 6, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:6")
    H.measure(chests(outs), WARMUP, WINDOW, function(rates)
      H.report("user_l_shape_2_in_6_out: %s", serpent.line(rates))
      local mean = H.assert_equal(rates, "output")
      near(mean, 2 * RATE / 6, "output mean")
      done()
    end)
  end)

  -- One block with an input and an output, then a second output on another side of the same
  -- block: 1:1 becomes 1:2 and both outputs get half.
  test("two_belts_on_one_block", function()
    async(WARMUP + WINDOW + 300)
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    ---@type table[]
    local outs = { H.sink(o, 4, 4, D.east, 3) }
    balancer.flush()
    local _, rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    outs[2] = H.sink(o, 4, 4, D.south, 3)
    balancer.flush()
    local _, rec2 = rec_of(b)
    assert(rec2.n == 1 and rec2.m == 2, "network " .. rec2.n .. ":" .. rec2.m .. ", expected 1:2")
    H.measure(chests(outs), WARMUP, WINDOW, function(rates)
      H.report("two_belts_on_one_block: %s", serpent.line(rates))
      H.assert_equal(rates, "output")
      for j, v in ipairs(rates) do
        near(v, RATE / 2, "output " .. j)
      end
      done()
    end)
  end)

  -- Two blocks; inserters take from the lower one, which is one more output with an equal share
  -- (2 belts + 1 port: 15 each). Then the port slows down (one inserter left, hand size 1): its
  -- unused share is spread equally over the two belts.
  test("inserter_port_share_and_recirc", function()
    async(2 * (WARMUP + WINDOW) + 300)
    local o = area(10, 10)
    local a = H.block(o, 4, 4, H.TIER)
    H.block(o, 4, 5, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    local outs = { H.sink(o, 4, 4, D.east, 3), H.sink(o, 4, 5, D.east, 3) }
    -- inserters face their pickup side: west of the block picking east, south of it picking north
    local i1 = H.put(o, 3, 5, "mb-test-inserter", D.east)
    local c1 = H.put(o, 2, 5, "mb-test-chest")
    local i2 = H.put(o, 4, 6, "mb-test-inserter", D.north)
    local c2 = H.put(o, 4, 7, "mb-test-chest")
    for _, ins in ipairs({ i1, i2 }) do
      local p = ins.pickup_position
      assert(math.floor(p.x) == math.floor(o.x + 4) and math.floor(p.y) == math.floor(o.y + 5), "inserter does not pick from the block")
    end
    balancer.flush()
    local _, rec = rec_of(a)
    assert(rec.n == 1 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:3")
    local port = rec.outputs[3]
    assert(port.kind == "inserter" and port.visible.linked_belt_type == "output", "third output is not an inserter port")
    local function count()
      local c = chests(outs)()
      local p = c1.get_item_count() + c2.get_item_count()
      for _, ins in ipairs({ i1, i2 }) do
        if ins.valid and ins.held_stack.valid_for_read then
          p = p + ins.held_stack.count
        end
      end
      c[3] = p
      return c
    end
    H.measure(count, WARMUP, WINDOW, function(rates)
      H.report("inserter_port_share: belts %.3f %.3f, port %.3f", rates[1], rates[2], rates[3])
      H.assert_equal(rates, "share")
      near(rates[1] + rates[2] + rates[3], RATE, "total")
      -- slow the port down
      i2.destroy({ raise_destroy = true })
      i1.inserter_stack_size_override = 1
      balancer.flush()
      local _, rec2 = rec_of(a)
      assert(rec2.m == 3, "the port went away with one inserter left")
      H.measure(count, WARMUP, WINDOW, function(slow)
        H.report("inserter_port_recirc: belts %.3f %.3f, port %.3f", slow[1], slow[2], slow[3])
        assert(slow[3] < RATE / 6, "the slowed port still takes " .. slow[3])
        H.assert_equal({ slow[1], slow[2] }, "belt")
        near(slow[1] + slow[2], RATE - slow[3], "belts take the rest")
        done()
      end)
    end)
  end)

  -- An inserter putting into a block is one more input: 200 plates from a chest come out of the
  -- block's output belt.
  test("inserter_input_counts", function()
    async(3300)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    local src = H.put(o, 4, 2, "mb-test-chest")
    src.insert({ name = "iron-plate", count = 200 })
    local ins = H.put(o, 4, 3, "mb-test-inserter", D.north)
    local d = ins.drop_position
    assert(math.floor(d.x) == math.floor(o.x + 4) and math.floor(d.y) == math.floor(o.y + 4), "inserter does not drop on the block")
    local out = H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local _, rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    assert(rec.inputs[1].kind == "inserter" and rec.inputs[1].visible.linked_belt_type == "input", "input is not an inserter port")
    after_ticks(3000, function()
      H.report("inserter_input_counts: sink %d of 200", out.chest.get_item_count())
      assert(out.chest.get_item_count() == 200, "sink holds " .. out.chest.get_item_count() .. " of 200")
      assert(H.count_box(box, "iron-plate") == 200, "plates lost or duplicated")
      done()
    end)
  end)

  -- A running 1:2 gets a third output (rebuilt 1:3), then loses one (rebuilt 1:2): every plate
  -- is still there after each change and at the end.
  test("adding_and_removing_a_belt_rebuilds_without_loss", function()
    async(4500)
    local o, box = area(12, 12)
    local a = H.block(o, 4, 4, H.TIER)
    H.block(o, 4, 5, H.TIER)
    local STOCK = 3000
    H.feed(o, 4, 4, D.west, 3, { stock = STOCK })
    H.sink(o, 4, 4, D.east, 3)
    H.sink(o, 4, 5, D.east, 3)
    balancer.flush()
    local mined = game.create_inventory(8)
    local function total()
      return H.count_box(box, "iron-plate") + mined.get_item_count("iron-plate")
    end
    after_ticks(600, function()
      H.sink(o, 4, 5, D.south, 3)
      balancer.flush()
      local _, rec = rec_of(a)
      assert(rec.m == 3, "network has " .. rec.m .. " outputs after adding one, expected 3")
      assert(total() == STOCK, "after adding: " .. total() .. " of " .. STOCK)
      after_ticks(600, function()
        local edge = H.at(o, 5, 4, "linked-belt")
        assert(edge and edge.name == "mb-edge-out-" .. H.BELT, "no output edge to mine")
        edge.mine({ inventory = mined, raise_destroyed = true })
        balancer.flush()
        local _, rec2 = rec_of(a)
        assert(rec2.m == 2, "network has " .. rec2.m .. " outputs after removing one, expected 2")
        assert(total() == STOCK, "after removing: " .. total() .. " of " .. STOCK)
        after_ticks(3000, function()
          H.report("adding_and_removing: %d of %d at the end", total(), STOCK)
          assert(total() == STOCK, "at the end: " .. total() .. " of " .. STOCK)
          mined.destroy()
          done()
        end)
      end)
    end)
  end)

  -- Two separate groups joined by one belt tile (Review Focus 2): the tile stays a plain belt
  -- and the two networks are linked directly. A is 1:2 (south output + the shared tile), B 1:1.
  test("shared_tile_between_groups", function()
    async(WARMUP + WINDOW + 300)
    local o, box = area(12, 10)
    local a = H.block(o, 3, 4, H.TIER)
    local b = H.block(o, 5, 4, H.TIER)
    H.put(o, 4, 4, H.BELT, D.east)
    H.feed(o, 3, 4, D.west, 3)
    local outs = { H.sink(o, 3, 4, D.south, 3), H.sink(o, 5, 4, D.east, 3) }
    balancer.flush()
    local ga, ra = rec_of(a)
    local gb, rb = rec_of(b)
    assert(ga ~= gb, "the two blocks are one group")
    assert(ra.n == 1 and ra.m == 2 and rb.n == 1 and rb.m == 1, "networks " .. ra.n .. ":" .. ra.m .. " and " .. rb.n .. ":" .. rb.m)
    local tile = H.at(o, 4, 4, "transport-belt")
    assert(tile and tile.name == H.BELT, "the shared tile is not a plain belt")
    local stock = H.count_box(box, "iron-plate")
    H.measure(chests(outs), WARMUP, WINDOW, function(rates)
      H.report("shared_tile_between_groups: A south %.3f, B east %.3f", rates[1], rates[2])
      H.assert_equal(rates, "output")
      near(rates[1], RATE / 2, "A south")
      assert(H.count_box(box, "iron-plate") == stock, "plates lost or duplicated")
      done()
    end)
  end)

  -- A group that feeds itself (Review Focus 2): block B's north output loops round into B's east
  -- side. 2:2 (source + loop in, sink + loop out) works like a vanilla loop: the sink gets the
  -- whole source, and no plate is lost.
  test("self_feeding_group", function()
    async(WARMUP + WINDOW + 300)
    local o, box = area(12, 12)
    local a = H.block(o, 3, 5, H.TIER)
    H.block(o, 4, 5, H.TIER)
    H.feed(o, 3, 5, D.west, 3)
    local out = H.sink(o, 3, 5, D.south, 3)
    for _, t in ipairs({ { 4, 4, D.north }, { 4, 3, D.east }, { 5, 3, D.east }, { 6, 3, D.south }, { 6, 4, D.south }, { 6, 5, D.west }, { 5, 5, D.west } }) do
      H.put(o, t[1], t[2], H.BELT, t[3])
    end
    balancer.flush()
    local _, rec = rec_of(a)
    assert(rec.n == 2 and rec.m == 2, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:2")
    local stock = H.count_box(box, "iron-plate")
    H.measure(chests({ out }), WARMUP, WINDOW, function(rates)
      H.report("self_feeding_group: sink %.3f", rates[1])
      near(rates[1], RATE, "sink")
      assert(H.count_box(box, "iron-plate") == stock, "plates lost or duplicated")
      done()
    end)
  end)

  -- A belt that turns into the block on its last tile is refused with a message: it stays a
  -- plain belt, and with no input the group has no network.
  test("curved_last_tile_refused_with_message", function()
    local o = area(10, 10)
    local seen = {}
    balancer.notify = function(player_index, refused, si)
      for _, r in ipairs(refused) do
        seen[#seen + 1] = r.reason
      end
      default_notify(player_index, refused, si)
    end
    local b = H.block(o, 4, 4, H.TIER)
    H.put(o, 3, 2, H.BELT, D.south)
    H.put(o, 3, 3, H.BELT, D.south)
    H.put(o, 3, 4, H.BELT, D.east) -- fed from its north side only: a curve into the block
    local last = H.at(o, 3, 4, "transport-belt")
    assert(last and last.belt_shape ~= "straight", "test setup: the last tile is not curved")
    H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local _, rec = rec_of(b)
    local reasons = {}
    for _, r in ipairs(rec.refused) do
      reasons[r.reason] = true
    end
    assert(reasons.curved, "not refused as curved: " .. serpent.line(rec.refused))
    assert(table_size(seen) > 0 and seen[1] == "curved", "no message: " .. serpent.line(seen))
    assert(rec.n == 0 and not rec.placed, "a network was built without inputs")
    assert(H.at(o, 3, 4, "transport-belt"), "the curved tile was swapped")
    assert(H.at(o, 5, 4, "transport-belt"), "the output was swapped although the group has no input")
  end)

  -- Belts passing alongside a block, and a belt that turns away from it on the next tile, are
  -- not outputs and get no items.
  test("passing_belt_is_not_an_output", function()
    async(1500)
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    local out = H.sink(o, 4, 4, D.east, 3)
    local passing = {}
    for x = 3, 5 do
      passing[#passing + 1] = H.put(o, x, 3, H.BELT, D.east)
    end
    passing[#passing + 1] = H.put(o, 3, 5, H.BELT, D.east)
    passing[#passing + 1] = H.put(o, 4, 5, H.BELT, D.south) -- fed from the west: turns away
    passing[#passing + 1] = H.put(o, 4, 6, H.BELT, D.south)
    balancer.flush()
    local _, rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    after_ticks(1200, function()
      for i, e in ipairs(passing) do
        assert(e.valid and e.type == "transport-belt", "passing belt " .. i .. " was swapped")
        assert(H.items_on(e) == 0, "passing belt " .. i .. " got " .. H.items_on(e) .. " items")
      end
      assert(out.chest.get_item_count() > 0, "the real output got nothing")
      done()
    end)
  end)

  -- A basic belt on an express balancer limits only its own output (15 items/s); the express
  -- output takes the rest (30).
  test("mixed_tier_belts", function()
    async(WARMUP + WINDOW + 300)
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    local fast = H.sink(o, 4, 4, D.east, 3)
    local slow = H.sink(o, 4, 4, D.south, 3, { belt = "transport-belt", loader = "basic" })
    balancer.flush()
    local _, rec = rec_of(b)
    assert(rec.m == 2, "network has " .. rec.m .. " outputs, expected 2")
    local edge = H.at(o, 4, 5, "linked-belt")
    assert(edge and edge.name == "mb-edge-out-transport-belt", "basic output edge is not a basic edge")
    local basic = (prototypes.entity["transport-belt"].belt_speed or 0) * 480
    H.measure(chests({ fast, slow }), WARMUP, WINDOW, function(rates)
      H.report("mixed_tier_belts: express %.3f, basic %.3f", rates[1], rates[2])
      near(rates[2], basic, "basic output")
      near(rates[1], RATE - basic, "express output")
      done()
    end)
  end)
end)
