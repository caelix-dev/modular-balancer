-- Exactness of placed networks in the real engine (express tier). Each test builds a rig
-- (tests/game/harness.lua): finite source chests and loaders on nauvis, linked into the hidden
-- network, and loaders into counting chests at the outputs. Rates are measured over WINDOW
-- ticks after a WARMUP-tick warm-up; every bound is 1 %. Results are logged with the prefix
-- MB-TEST (factorio-current.log). Plain assert, not luassert.
local H = require("tests.game.harness")
-- Test code only: the flow model is offline in the product (scripts/flow.lua header), but
-- inserter_share compares the engine with it (Ruling 6).
local flow = require("scripts.flow")

local WARMUP, WINDOW = 600, 3600
-- inputs_drawn_equally only: behind half-speed outputs the network and harness fill up for a
-- while (3:5: about 1 300 items at a 22.5/s surplus, roughly 3 500 ticks), and the claim is
-- about the backed-up steady state, so that test warms up for DRAW_WARMUP ticks (a deviation
-- from the brief's 600, review I1) and checks that the draw equals what is delivered.
local DRAW_WARMUP = 6000
local RATE = H.RATE
---@type {[1]: integer, [2]: integer}[]
local RATIOS = { { 2, 3 }, { 3, 5 }, { 8, 3 }, { 1, 5 }, { 5, 1 }, { 1, 1 } }

---@return fun(): number[]
local function sink_counts(rig, item)
  return function()
    local c = {}
    for j, sink in ipairs(rig.sinks) do
      c[j] = item and sink.get_item_count(item) or sink.get_item_count()
    end
    return c
  end
end

local function fmt(list)
  local t = {}
  for i, v in ipairs(list) do
    t[i] = string.format("%.3f", v)
  end
  return table.concat(t, " ")
end

local function near(v, expected, what)
  assert(math.abs(v - expected) <= expected * 0.01,
    string.format("%s: %.3f, expected %.3f within 1 %%", what, v, expected))
end

local saved_bonus = 0

describe("exactness", function()
  after_each(function()
    H.teardown_all()
  end)

  before_all(function()
    saved_bonus = game.forces.player.bulk_inserter_capacity_bonus
    -- the belt port's three bulk inserters must keep up with one output's share (F3)
    game.forces.player.bulk_inserter_capacity_bonus = 11
  end)

  after_all(function()
    game.forces.player.bulk_inserter_capacity_bonus = saved_bonus
  end)

  for _, r in ipairs(RATIOS) do
    local n, m = r[1], r[2]
    local tag = n .. "_" .. m

    test("outputs_equal_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m })
      H.measure(sink_counts(rig), WARMUP, WINDOW, function(rates)
        H.report("outputs_equal %d:%d: outputs %s items/s", n, m, fmt(rates))
        H.assert_equal(rates, "output")
        done()
      end)
    end)

    test("inputs_drawn_equally_" .. tag, function()
      async(DRAW_WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, sink = "half" })
      H.measure(function()
        local c = sink_counts(rig)()
        for i = 1, n do
          c[m + i] = H.drawn(rig, i)
        end
        return c
      end, DRAW_WARMUP, WINDOW, function(rates)
        local outs, ins = { table.unpack(rates, 1, m) }, { table.unpack(rates, m + 1, m + n) }
        H.report("inputs_drawn_equally %d:%d (outputs at half speed): inputs %s, outputs %s items/s", n, m, fmt(ins), fmt(outs))
        H.assert_equal(ins, "input")
        -- steady state: the outputs run at half speed and the inputs give exactly that
        near(H.sum(outs), math.min(n * RATE, m * RATE / 2), "total delivered")
        near(H.sum(ins), H.sum(outs), "draw against delivered")
        done()
      end)
    end)

    test("throughput_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m })
      H.measure(sink_counts(rig), WARMUP, WINDOW, function(rates)
        local total = H.sum(rates)
        H.report("throughput %d:%d: total %.3f items/s (min(n, m) belts = %.3f)", n, m, total, math.min(n, m) * RATE)
        near(total, math.min(n, m) * RATE, "total throughput")
        done()
      end)
    end)
  end

  -- User requirement (2026-10-24): outputs stay equal when one input is fed slower.
  for _, r in ipairs({ { 2, 4 }, { 3, 5 } }) do
    local n, m = r[1], r[2]
    test("outputs_equal_unequal_inputs_" .. n .. "_" .. m, function()
      async(WARMUP + WINDOW + 300)
      local feed = { "slow" }
      local rig = H.rig({ n = n, m = m, feed = feed })
      H.measure(sink_counts(rig), WARMUP, WINDOW, function(rates)
        local supply = RATE / 3 + (n - 1) * RATE
        H.report("outputs_equal_unequal_inputs %d:%d (input 1 at a third): outputs %s items/s, total %.3f (supply %.3f)",
          n, m, fmt(rates), H.sum(rates), supply)
        H.assert_equal(rates, "output")
        near(H.sum(rates), supply, "total")
        done()
      end)
    end)
  end

  test("mixed_items_keep_lanes", function()
    async(WARMUP + WINDOW + 300)
    local rig = H.rig({ n = 2, m = 3, feed = { "lanes", "lanes" } })
    local counts = H.lane_counter(rig)
    local function flat()
      local c = {}
      for j = 1, 3 do
        c[#c + 1] = counts[j][1]["iron-plate"] or 0
        c[#c + 1] = counts[j][2]["copper-plate"] or 0
      end
      return c
    end
    H.measure(flat, WARMUP, WINDOW, function(rates)
      local iron, copper = { rates[1], rates[3], rates[5] }, { rates[2], rates[4], rates[6] }
      H.report("mixed_items_keep_lanes 2:3: iron (left) %s, copper (right) %s items/s", fmt(iron), fmt(copper))
      for j = 1, 3 do
        local wrong = (counts[j][1]["copper-plate"] or 0) + (counts[j][2]["iron-plate"] or 0)
        local other = H.sum(counts[j][1]) + H.sum(counts[j][2]) - (counts[j][1]["iron-plate"] or 0)
          - (counts[j][2]["copper-plate"] or 0) - wrong
        assert(wrong == 0 and other == 0, "output " .. j .. ": " .. wrong .. " items on the wrong lane, " .. other .. " others")
      end
      H.assert_equal(iron, "iron output")
      H.assert_equal(copper, "copper output")
      near(H.sum(iron), RATE, "iron total")
      near(H.sum(copper), RATE, "copper total")
      done()
    end)
  end)

  test("backpressure_then_release_moves_again", function()
    async(WARMUP + 600 + WINDOW + 300)
    local rig = H.rig({ n = 3, m = 5 })
    after_ticks(WARMUP, function()
      for _, l in ipairs(rig.sink_loaders) do
        l.disabled_by_script = true
      end
      local blocked = sink_counts(rig)()
      after_ticks(600, function()
        local still = sink_counts(rig)()
        for j = 1, 5 do
          assert(still[j] == blocked[j], "output " .. j .. " moved while blocked")
        end
        for _, l in ipairs(rig.sink_loaders) do
          l.disabled_by_script = false
        end
        H.measure(sink_counts(rig), 1, WINDOW, function(rates)
          H.report("backpressure_then_release 3:5: after release, outputs %s items/s, total %.3f", fmt(rates), H.sum(rates))
          H.assert_equal(rates, "output")
          assert(H.sum(rates) >= 3 * RATE * 0.99, "flow did not resume at full rate: " .. H.sum(rates))
          done()
        end)
      end)
    end)
  end)

  -- F3: one extra network output feeds a belt port (an output linked belt under a block, a dead
  -- end) that three inserters take from. The port must get exactly a belt output's share.
  for _, r in ipairs({ { 2, 3 }, { 3, 5 } }) do
    local n, m = r[1], r[2]
    local tag = n .. "_" .. m

    test("inserter_share_" .. tag, function()
      async(2 * (WARMUP + WINDOW) + 300)
      local rig = H.rig({ n = n, m = m, port = 1 })
      local function counts()
        local c = sink_counts(rig)()
        c[#c + 1] = H.port_count(rig)
        return c
      end
      H.measure(counts, WARMUP, WINDOW, function(rates)
        H.report("inserter_share %d:%d: belt outputs %s, port %.3f items/s", n, m, fmt({ table.unpack(rates, 1, m) }), rates[m + 1])
        H.assert_equal(rates, "output (the last is the port)")
        -- throttled: one slow inserter (hand size 1), the others off
        rig.inserters[1].disabled_by_script = true
        rig.inserters[2].disabled_by_script = true
        rig.inserters[3].inserter_stack_size_override = 1
        H.measure(counts, WARMUP, WINDOW, function(slow)
          -- Ruling 6: the port behaves like a belt output. Its unused share goes where a slow
          -- belt output's would (vanilla splitter behaviour), so the result must match the flow
          -- model with the port's demand set to its measured rate, and nothing is lost.
          local belts = { table.unpack(slow, 1, m) }
          local net = rig.net
          local supply, demand = {}, {}
          for i = 1, n do
            supply[i] = 1
          end
          for j = 1, m do
            demand[j] = 1
          end
          demand[m + 1] = slow[m + 1] / RATE
          local state = flow.solve(net, supply, demand)
          local model = {}
          for j = 1, m + 1 do
            model[j] = state.f[state.out_edge[j]] * RATE
          end
          H.report("inserter_share %d:%d throttled: belt outputs %s, port %.3f items/s; flow model %s",
            n, m, fmt(belts), slow[m + 1], fmt(model))
          assert(slow[m + 1] < rates[m + 1] * 0.5, "the port was not throttled")
          near(H.sum(slow), H.sum(rates), "belts plus port against the free phase")
          for j = 1, m do
            near(slow[j], model[j], "belt output " .. j .. " against the flow model")
          end
          done()
        end)
      end)
    end)

    test("inserter_share_lanes_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local feed = {}
      for i = 1, n do
        feed[i] = "lanes"
      end
      local rig = H.rig({ n = n, m = m, port = 1, feed = feed })
      local function counts()
        local iron, copper = sink_counts(rig, "iron-plate")(), sink_counts(rig, "copper-plate")()
        iron[#iron + 1] = H.port_count(rig, "iron-plate")
        copper[#copper + 1] = H.port_count(rig, "copper-plate")
        for _, v in ipairs(copper) do
          iron[#iron + 1] = v
        end
        return iron
      end
      H.measure(counts, WARMUP, WINDOW, function(rates)
        local iron, copper = { table.unpack(rates, 1, m + 1) }, { table.unpack(rates, m + 2, 2 * m + 2) }
        H.report("inserter_share_lanes %d:%d: iron %s, copper %s items/s (last = port)", n, m, fmt(iron), fmt(copper))
        H.assert_equal(iron, "iron output (the last is the port)")
        H.assert_equal(copper, "copper output (the last is the port)")
        done()
      end)
    end)
  end

  -- F5: balance lanes with only the left input lanes fed. Both lanes of every output carry the
  -- same, and the total is min(n / 2, m) belts (only n / 2 belts are supplied).
  for _, r in ipairs({ { 2, 3 }, { 8, 3 } }) do
    local n, m = r[1], r[2]
    test("lane_balance_" .. n .. "_" .. m, function()
      async(WARMUP + WINDOW + 300)
      local feed = {}
      for i = 1, n do
        feed[i] = "left"
      end
      local rig = H.rig({ n = n, m = m, balance_lanes = true, feed = feed })
      local counts = H.lane_counter(rig)
      local function flat()
        local c = {}
        for j = 1, m do
          c[#c + 1] = H.sum(counts[j][1])
          c[#c + 1] = H.sum(counts[j][2])
        end
        return c
      end
      H.measure(flat, WARMUP, WINDOW, function(rates)
        local expected = math.min(n / 2, m) * RATE
        H.report("lane_balance %d:%d (left lanes only): lanes (left right per output) %s items/s, total %.3f (expected %.3f)",
          n, m, fmt(rates), H.sum(rates), expected)
        H.assert_equal(rates, "lane")
        near(H.sum(rates), expected, "total")
        done()
      end)
    end)
  end
end)
