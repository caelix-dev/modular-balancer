-- builder.rebuild: a network replaced by another keeps every item (carried onto the new
-- network's belts, the rest into its buffer chest, which drains into input 1). Express tier.
-- Plain assert, not luassert.
local network = require("scripts.network")
local builder = require("scripts.builder")
local H = require("tests.game.harness")

local RATE = H.RATE

local function stock_of(rig)
  local stock = 0.0
  for _, list in ipairs(rig.sources) do
    stock = stock + #list * rig.stock
  end
  return stock
end

local function assert_conserved(rig, what)
  local total, stock = H.total_items(rig), stock_of(rig)
  assert(total == stock, what .. ": " .. total .. " items, expected " .. stock)
end

-- A 3:m rig whose outputs are blocked until no input draws any more (the network is full).
-- Calls back with the rig once full.
local function backed_up(opts, callback)
  local rig = H.rig(opts)
  for _, l in ipairs(rig.sink_loaders) do
    l.disabled_by_script = true
  end
  local last = -1.0
  local function poll()
    after_ticks(300, function()
      local d = 0.0
      for i = 1, rig.n do
        d = d + H.drawn(rig, i)
      end
      if d == last then
        callback(rig)
      else
        last = d
        poll()
      end
    end)
  end
  poll()
end

local function set_feed(rig, on)
  for _, f in ipairs(rig.feeders) do
    f.disabled_by_script = not on
  end
end

local function set_sinks(rig, on)
  for _, l in ipairs(rig.sink_loaders) do
    l.disabled_by_script = not on
  end
end

describe("rebuild", function()
  after_each(function()
    H.teardown_all()
  end)

  test("rebuild_keeps_every_item", function()
    async(9000 + 3600)
    backed_up({ n = 3, m = 5, stock = 4000 }, function(rig)
      local inside = H.network_items(rig)
      assert_conserved(rig, "before")
      H.rebuild(rig, 5)
      local after = H.network_items(rig)
      H.report("rebuild 3:5 -> 3:5 (backed up): %d items in the network before, %d after (%d in the buffer)",
        inside, after, rig.placed.buffer.get_item_count())
      assert(after == inside, "network holds " .. after .. " of " .. inside)
      assert_conserved(rig, "right after the rebuild")
      set_sinks(rig, true)
      -- the buffer shares input 1 with a full feed, so it drains at about half a belt
      after_ticks(3600, function()
        assert_conserved(rig, "3 600 ticks after the release")
        assert(rig.placed.buffer.get_item_count() == 0, "buffer did not drain")
        done()
      end)
    end)
  end)

  -- Review Focus 1: the new network is much smaller and cannot hold the items on its belts.
  test("shrink_keeps_every_item", function()
    async(9000 + 6000)
    backed_up({ n = 3, m = 5, stock = 2000 }, function(rig)
      set_feed(rig, false)
      local inside = H.network_items(rig)
      H.rebuild(rig, 1)
      local buffered = rig.placed.buffer.get_item_count()
      H.report("shrink 3:5 -> 3:1: %d items in the network, %d of them in the buffer (%d slots)",
        inside, buffered, #rig.placed.buffer.get_inventory(defines.inventory.chest))
      assert(H.network_items(rig) == inside, "network holds " .. H.network_items(rig) .. " of " .. inside)
      assert(buffered > 0, "nothing went into the buffer: the shrink test does not test the buffer")
      assert_conserved(rig, "right after the shrink")
      local before = rig.sinks[1].get_item_count()
      set_sinks(rig, true)
      after_ticks(6000, function()
        local out = rig.sinks[1].get_item_count() - before
        H.report("shrink 3:5 -> 3:1: %d items left through the single output in 6 000 ticks, %d left in the network",
          out, H.network_items(rig))
        assert(H.network_items(rig) == 0, H.network_items(rig) .. " items still in the network after 6 000 ticks")
        assert(out >= inside, "only " .. out .. " of " .. inside .. " came out")
        assert_conserved(rig, "6 000 ticks after the shrink")
        done()
      end)
    end)
  end)

  test("grow_keeps_every_item", function()
    async(9000 + 3600 + 300)
    backed_up({ n = 3, m = 1, stock = 2000, rows = 8 }, function(rig)
      local inside = H.network_items(rig)
      H.rebuild(rig, 8)
      H.report("grow 3:1 -> 3:8: %d items in the network before, %d after", inside, H.network_items(rig))
      assert(H.network_items(rig) == inside, "network holds " .. H.network_items(rig) .. " of " .. inside)
      assert_conserved(rig, "right after the grow")
      set_sinks(rig, true)
      after_ticks(3600, function()
        assert_conserved(rig, "3 600 ticks after the grow")
        for j = 1, 8 do
          assert(rig.sinks[j].get_item_count() > 0, "output " .. j .. " delivered nothing after the grow")
        end
        done()
      end)
    end)
  end)

  -- Items of every quality survive a rebuild, on belts and in the buffer: a 3:5 with normal and
  -- (Space Age) uncommon plates on its belts rebuilt as a 1:1, which holds only a few on belts.
  test("quality_kept_on_rebuild", function()
    local old = assert(builder.place(assert(network.build(3, 5)), "express"))
    ---@type string[]
    local qualities = { "normal" }
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.quality["uncommon"] then
      qualities[2] = "uncommon"
    end
    local put = 0
    for _, e in ipairs(old.entities) do
      if e.type == "linked-belt" then
        for _, li in ipairs(H.LINES) do
          for _, pos in ipairs({ 0, 0.25 }) do
            local q = qualities[put % #qualities + 1]
            if e.get_transport_line(li).insert_at(pos, { name = "iron-plate", quality = q, count = 1 }) then
              put = put + 1
            end
          end
        end
      end
    end
    local before = builder.contents(old)
    local new = assert(builder.rebuild(old, assert(network.build(1, 1)), "express"))
    local after = builder.contents(new)
    assert(#before == #qualities, "the test put " .. #before .. " qualities, expected " .. #qualities)
    H.report("quality_kept_on_rebuild: %d plates, before %s, after %s, %d in the buffer", put, serpent.line(before),
      serpent.line(after), new.buffer.get_item_count())
    assert(#old.entities == 0, "the old network was not destroyed")
    assert(new.buffer.get_item_count() > 0, "nothing went into the buffer")
    assert(serpent.line(before) == serpent.line(after), "contents changed: " .. serpent.line(before) .. " -> " .. serpent.line(after))
    builder.destroy(new)
  end)

  -- A rebuild that cannot be placed leaves the old network as it was.
  test("failed_rebuild_keeps_the_old_network", function()
    local old = assert(builder.place(assert(network.build(3, 5)), "express"))
    old.entities[#old.entities].get_transport_line(1).insert_at(0, { name = "iron-plate", count = 1 })
    builder.fail_after = 10
    local new, err = builder.rebuild(old, assert(network.build(3, 1)), "express")
    builder.fail_after = nil
    assert(new == nil and err, "rebuild did not fail")
    assert(#old.entities > 0 and old.entities[1].valid, "the old network was touched")
    local items = builder.destroy(old)
    assert(#items == 1 and items[1].count == 1, "old network lost its item: " .. serpent.line(items))
  end)

  -- After a shrink the buffer drains through input 1 and the output still gets full speed.
  test("buffer_drains_at_full_output_rate", function()
    async(9000 + 3600 + 600)
    backed_up({ n = 3, m = 5, stock = 4000 }, function(rig)
      H.rebuild(rig, 1)
      set_sinks(rig, true)
      H.measure(function()
        return { rig.sinks[1].get_item_count() }
      end, 600, 1800, function(rates)
        H.report("after shrink to 3:1: output %.3f items/s while the buffer drains (%d left in the buffer)", rates[1],
          rig.placed.buffer.get_item_count())
        assert(math.abs(rates[1] - RATE) <= RATE * 0.01, "output " .. rates[1] .. " after the shrink")
        done()
      end)
    end)
  end)
end)
