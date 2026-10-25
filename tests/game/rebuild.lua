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

-- The item-data tests run on both carry paths: builder.rebuild (copies the stacks, then destroys
-- the old network) and builder.rebuild_staged (places the new network, seals the old one and
-- drains it item by item: what the live balancer does over several ticks, scripts/balancer.lua).
---@type { tag: string, rebuild: fun(old: table, net: mb.Network, tier: string): table?, string? }[]
local MODES = {
  { tag = "", rebuild = builder.rebuild },
  { tag = "_staged", rebuild = builder.rebuild_staged },
}

describe("rebuild", function()
  after_each(function()
    builder.fail_after = nil
    builder.max_buffer_slots = 65535
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
        -- review M5: the drained buffer shrinks back to one slot
        assert(builder.compact(rig.placed), "compact did not shrink the drained buffer")
        assert(#rig.placed.buffer.get_inventory(defines.inventory.chest) == 1, "buffer not back to one slot")
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
  for _, mode in ipairs(MODES) do
    test("quality_kept_on_rebuild" .. mode.tag, function()
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
      local new = assert(mode.rebuild(old, assert(network.build(1, 1)), "express"))
      local after = builder.contents(new)
      assert(#before == #qualities, "the test put " .. #before .. " qualities, expected " .. #qualities)
      H.report("quality_kept_on_rebuild: %d plates, before %s, after %s, %d in the buffer", put, serpent.line(before),
        serpent.line(after), new.buffer.get_item_count())
      assert(#old.entities == 0, "the old network was not destroyed")
      assert(new.buffer.get_item_count() > 0, "nothing went into the buffer")
      assert(serpent.line(before) == serpent.line(after), "contents changed: " .. serpent.line(before) .. " -> " .. serpent.line(after))
      builder.destroy(new)
    end)
  end

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

  -- Item data survives a rebuild (review I1): blueprints with entities and labels, and a modular
  -- armor with equipment in its grid, on the belts of a 3:5 rebuilt as a 1:1 (so most of them go
  -- through the buffer). Every stack is found again, on the new belts or in the buffer.
  for _, mode in ipairs(MODES) do
    test("item_data_kept_on_rebuild" .. mode.tag, function()
      local old = assert(builder.place(assert(network.build(3, 5)), "express"))
      local inv = game.create_inventory(40)
      local want = {}
      for i = 1, 20 do
        inv[i].set_stack({ name = "blueprint" })
        inv[i].set_blueprint_entities({ { entity_number = 1, name = "iron-chest", position = { 0.5, 0.5 } } })
        inv[i].label = "bp-" .. i
        want["bp-" .. i] = true
      end
      inv[21].set_stack({ name = "modular-armor" })
      local grid = inv[21].grid or inv[21].create_grid()
      assert(grid and grid.put({ name = "solar-panel-equipment" }), "could not put equipment into the armor")
      local lines = {}
      for _, e in ipairs(old.entities) do
        if e.type == "linked-belt" then
          for _, li in ipairs(H.LINES) do
            lines[#lines + 1] = e.get_transport_line(li)
          end
        end
      end
      for i = 1, 21 do
        assert(lines[i].insert_at(0.1, inv[i]), "could not put stack " .. i .. " (" .. inv[i].name .. ") on an old belt")
      end
      inv.destroy()
      local new = assert(mode.rebuild(old, assert(network.build(1, 1)), "express"))
      local found, on_belts, in_buffer = {}, 0, 0
      local armor = nil ---@type table?
      local function look(st, where)
        if st.name == "blueprint" then
          assert(st.get_blueprint_entity_count() == 1, (st.label or "?") .. " lost its entities (" .. where .. ")")
          found[st.label] = true
        elseif st.name == "modular-armor" then
          armor = st.grid and st.grid.get_contents() or {}
        end
        if where == "belt" then
          on_belts = on_belts + 1
        else
          in_buffer = in_buffer + 1
        end
      end
      for _, e in ipairs(new.entities) do
        if e.type == "container" then
          local binv = e.get_inventory(defines.inventory.chest)
          for i = 1, #binv do
            if binv[i].valid_for_read then
              look(binv[i], "buffer")
            end
          end
        else
          for i = 1, e.get_max_transport_line_index() do
            for _, d in ipairs(e.get_transport_line(i).get_detailed_contents()) do
              look(d.stack, "belt")
            end
          end
        end
      end
      H.report("item_data_kept_on_rebuild: 20 blueprints and 1 armor; %d stacks on the new belts, %d in the buffer; armor grid %s",
        on_belts, in_buffer, serpent.line(armor))
      for label in pairs(want) do
        assert(found[label], label .. " was not found after the rebuild")
      end
      assert(armor and #armor == 1 and armor[1].name == "solar-panel-equipment", "armor lost its equipment: " .. serpent.line(armor))
      builder.destroy(new)
    end)
  end

  -- Space Age: spoilage survives a rebuild (review I1). Yumako at known spoil fractions on the
  -- belts of a 3:5 rebuilt as a 1:1. Items carried onto belts keep their own fraction; stacks
  -- merged in the buffer average theirs (as in any chest). So the test checks the total spoilage
  -- (sum of spoil_percent x count), that nothing came back fresher than any item put in, and
  -- that the items on the new belts still show the spread (the freshest one, 0.2, is among the
  -- first on the belts).
  for _, mode in ipairs(MODES) do
    test("spoilage_kept_on_rebuild" .. mode.tag, function()
      ---@diagnostic disable-next-line: unnecessary-if
      if not prototypes.item["yumako"] then
        H.report("spoilage_kept_on_rebuild: skipped (no Space Age)")
        return
      end
      local old = assert(builder.place(assert(network.build(3, 5)), "express"))
      local put, sum_before = 0, 0.0
      for _, e in ipairs(old.entities) do
        if e.type == "linked-belt" then
          for _, li in ipairs(H.LINES) do
            local f = 0.2 + 0.6 * ((put % 7) / 6)
            if e.get_transport_line(li).insert_at(0.1, { name = "yumako", count = 1, spoil_percent = f }) then
              put = put + 1
              sum_before = sum_before + f
            end
          end
        end
      end
      local new = assert(mode.rebuild(old, assert(network.build(1, 1)), "express"))
      local count, sum_after, freshest = 0, 0.0, 1.0
      local function look(st)
        count = count + st.count
        sum_after = sum_after + st.spoil_percent * st.count
        freshest = math.min(freshest, st.spoil_percent)
      end
      for _, e in ipairs(new.entities) do
        if e.type == "container" then
          local binv = e.get_inventory(defines.inventory.chest)
          for i = 1, #binv do
            if binv[i].valid_for_read then
              look(binv[i])
            end
          end
        else
          for i = 1, e.get_max_transport_line_index() do
            for _, d in ipairs(e.get_transport_line(i).get_detailed_contents()) do
              look(d.stack)
            end
          end
        end
      end
      H.report("spoilage_kept_on_rebuild: %d yumako, total spoilage %.4f before, %.4f after, freshest after %.4f (freshest put 0.2)",
        put, sum_before, sum_after, freshest)
      assert(count == put, count .. " of " .. put .. " yumako after the rebuild")
      assert(math.abs(sum_after - sum_before) <= sum_before * 0.01, "total spoilage changed")
      assert(freshest >= 0.19, "an item came back fresher than any put in: " .. freshest)
      assert(freshest <= 0.21, "no item kept its own spoil fraction on the belts (freshest " .. freshest .. ")")
      builder.destroy(new)
    end)
  end

  -- Review M2: a rebuild that needs more buffer slots than allowed is refused and leaves the old
  -- network (and the region count) as it was.
  test("too_many_items_keeps_the_old_network", function()
    local old = assert(builder.place(assert(network.build(3, 5)), "express"))
    local put = 0
    for _, e in ipairs(old.entities) do
      if e.type == "linked-belt" then
        for k, li in ipairs(H.LINES) do
          if e.get_transport_line(li).insert_at(0.1, { name = k == 1 and "iron-plate" or "copper-plate", count = 1 }) then
            put = put + 1
          end
        end
      end
    end
    local before = serpent.line(builder.contents(old))
    local regions = 0
    for _ in pairs(storage.regions.used) do
      regions = regions + 1
    end
    builder.max_buffer_slots = 1
    local new, err = builder.rebuild(old, assert(network.build(1, 1)), "express")
    builder.max_buffer_slots = 65535
    local after_regions = 0
    for _ in pairs(storage.regions.used) do
      after_regions = after_regions + 1
    end
    H.report("too_many_items: %d items, rebuild returned %s, %s", put, tostring(new), tostring(err))
    assert(new == nil and err == "too-many-items", "rebuild was not refused: " .. tostring(err))
    assert(serpent.line(builder.contents(old)) == before, "the old network changed: " .. serpent.line(builder.contents(old)))
    assert(after_regions == regions, "region count changed: " .. regions .. " -> " .. after_regions)
    builder.destroy(old)
  end)

  -- Review M3: mb-hidden-never can only appear by cheating. contents leaves it out and a rebuild
  -- drops it (so a jam it causes clears), while every other item is kept.
  for _, mode in ipairs(MODES) do
    test("never_item_is_dropped_on_rebuild" .. mode.tag, function()
      local old = assert(builder.place(assert(network.build(3, 5)), "express"))
      local lines = {}
      for _, e in ipairs(old.entities) do
        if e.type == "linked-belt" then
          lines[#lines + 1] = e.get_transport_line(1)
        end
      end
      assert(lines[1].insert_at(0.1, { name = "mb-hidden-never", count = 1 }), "could not put the never item on a belt")
      assert(lines[2].insert_at(0.1, { name = "iron-plate", count = 1 }), "could not put a plate on a belt")
      local before = builder.contents(old)
      local new = assert(mode.rebuild(old, assert(network.build(3, 5)), "express"))
      local after = builder.contents(new)
      assert(#before == 1 and before[1].name == "iron-plate", "contents listed: " .. serpent.line(before))
      assert(serpent.line(after) == serpent.line(before), "after the rebuild: " .. serpent.line(after))
      builder.destroy(new)
    end)
  end

  -- Review M7: cost of a rebuild of a large, full network (recorded). A 64:64 with every
  -- position of every hidden linked belt holding a plate, rebuilt as a 64:64.
  test("rebuild_cost_at_64_64", function()
    local net = assert(network.build(64, 64))
    local old = assert(builder.place(net, "express"))
    local put = 0
    for _, e in ipairs(old.entities) do
      if e.type == "linked-belt" then
        for _, li in ipairs(H.LINES) do
          for _, pos in ipairs({ 0, 0.25 }) do
            if e.get_transport_line(li).insert_at(pos, { name = "iron-plate", count = 1 }) then
              put = put + 1
            end
          end
        end
      end
    end
    -- an empty place of the same network, for comparison: the rest of the rebuild is carrying the
    -- items and destroying the old network
    local place_only = helpers.create_profiler()
    local empty = assert(builder.place(net, "express"))
    place_only.stop()
    builder.destroy(empty)
    local profiler = helpers.create_profiler()
    local new = assert(builder.rebuild(old, net, "express"))
    profiler.stop()
    log({ "", "MB-TEST rebuild_cost_at_64_64: an empty place of the same network took ", place_only })
    local after = 0
    for _, it in ipairs(builder.contents(new)) do
      after = after + it.count
    end
    log({ "", "MB-TEST rebuild_cost_at_64_64: ", tostring(#new.entities), " entities, ", tostring(put),
      " items carried, ", tostring(new.buffer.get_item_count()), " into the buffer; rebuild took ", profiler })
    assert(after == put, after .. " of " .. put .. " items after the rebuild")
    builder.destroy(new)
  end)

  -- Review N1: a second rebuild while the buffer still holds full stacks (a player removes two
  -- output belts in a row). Shrink a backed-up 3:5 to 3:1, then at once rebuild as 3:2: the
  -- buffer's 100-plate stacks are split onto the new belts, and every count stays exact.
  test("second_rebuild_with_full_buffer_keeps_every_item", function()
    async(9000)
    backed_up({ n = 3, m = 5, stock = 2000 }, function(rig)
      set_feed(rig, false)
      local before = serpent.line(builder.contents(rig.placed))
      H.rebuild(rig, 1)
      local mid = serpent.line(builder.contents(rig.placed))
      local buffered = rig.placed.buffer.get_item_count()
      H.rebuild(rig, 2)
      local after = serpent.line(builder.contents(rig.placed))
      H.report("second rebuild: 3:5 %s -> 3:1 %s (%d in the buffer) -> 3:2 %s (%d in the buffer)", before, mid, buffered,
        after, rig.placed.buffer.get_item_count())
      assert(buffered > 0, "the first shrink left the buffer empty")
      assert(mid == before and after == before, "contents changed: " .. before .. " / " .. mid .. " / " .. after)
      assert_conserved(rig, "after the second rebuild")
      done()
    end)
  end)

  -- Review N3: stacks of several items with per-item state (partly used magazines and repair
  -- packs) and a plain stack, all in the old buffer. Ammo and durability totals and the plate
  -- count are exact after a rebuild.
  for _, mode in ipairs(MODES) do
    test("partial_stacks_keep_item_state" .. mode.tag, function()
      local probe = game.create_inventory(2)
      probe[1].set_stack({ name = "firearm-magazine" })
      probe[2].set_stack({ name = "repair-pack" })
      local mag, dur = probe[1].ammo, probe[2].durability
      probe.destroy()
      local old = assert(builder.place(assert(network.build(3, 5)), "express"))
      old.buffer.set_inventory_size_override(defines.inventory.chest, 3)
      local binv = old.buffer.get_inventory(defines.inventory.chest)
      assert(binv.insert({ name = "firearm-magazine", count = 10, ammo = 3 }) == 10, "magazines")
      assert(binv.insert({ name = "repair-pack", count = 5, durability = dur / 2 }) == 5, "repair packs")
      assert(binv.insert({ name = "iron-plate", count = 50 }) == 50, "plates")
      local function totals(placed)
        ---@type {rounds: number, mags: integer, wear: number, packs: integer, plates: integer}
        local t = { rounds = 0.0, mags = 0, wear = 0.0, packs = 0, plates = 0 }
        local function look(st)
          if st.name == "firearm-magazine" then
            t.mags = t.mags + st.count
            t.rounds = t.rounds + (st.count - 1) * mag + st.ammo
          elseif st.name == "repair-pack" then
            t.packs = t.packs + st.count
            t.wear = t.wear + (st.count - 1) * dur + st.durability
          elseif st.name == "iron-plate" then
            t.plates = t.plates + st.count
          end
        end
        for _, e in ipairs(placed.entities) do
          if e.type == "container" then
            local inv = e.get_inventory(defines.inventory.chest)
            for i = 1, #inv do
              if inv[i].valid_for_read then
                look(inv[i])
              end
            end
          else
            for i = 1, e.get_max_transport_line_index() do
              for _, d in ipairs(e.get_transport_line(i).get_detailed_contents()) do
                look(d.stack)
              end
            end
          end
        end
        return t
      end
      local before = totals(old)
      local new = assert(mode.rebuild(old, assert(network.build(3, 5)), "express"))
      local after = totals(new)
      H.report("partial_stacks: before %s, after %s (%d left in the buffer)", serpent.line(before), serpent.line(after),
        new.buffer.get_item_count())
      for _, key in ipairs({ "mags", "rounds", "packs", "wear", "plates" }) do
        assert(math.abs(after[key] - before[key]) < 1e-6, key .. ": " .. before[key] .. " -> " .. after[key])
      end
      assert(after.plates == 50 and new.buffer.get_item_count("iron-plate") < 50, "the plates were not split onto belts")
      builder.destroy(new)
    end)
  end
end)
