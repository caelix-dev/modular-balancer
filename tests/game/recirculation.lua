-- F8 (experimental, not the product design of Plan 1): equal redistribution by recirculation.
-- Every network output passes a priority splitter whose overflow loops back into the network
-- (harness opts.recirc), so when one output takes less, the others share the rest equally.
-- Express tier, rates over WINDOW ticks after WARMUP. Logged with the prefix MB-TEST.
-- The loops take longer to settle than the plain network: from an empty rig, the total reaches
-- its steady value after about 2 400-3 000 ticks (600 for the plain network), so WARMUP is
-- 3 000 here (docs/feasibility.md F8).
-- Plain assert, not luassert.
local H = require("tests.game.harness")

local WARMUP, WINDOW = 3000, 3600
local RATE = H.RATE

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

---@return fun(): number[]
local function counts(rig)
  return function()
    local c = {}
    for j, sink in ipairs(rig.sinks) do
      c[j] = sink.get_item_count()
    end
    if rig.port then
      c[#c + 1] = H.port_count(rig)
    end
    return c
  end
end

-- No item lost or duplicated: everything the rig holds or delivered equals the stock.
local function assert_conserved(rig, what)
  local stock = 0.0
  for _, list in ipairs(rig.sources) do
    stock = stock + #list * rig.stock
  end
  local total = H.total_items(rig)
  assert(total == stock, what .. ": " .. total .. " items, expected " .. stock)
end

local saved_bonus = 0

describe("F8 recirculation", function()
  after_each(function()
    H.teardown_all()
  end)

  before_all(function()
    saved_bonus = game.forces.player.bulk_inserter_capacity_bonus
    game.forces.player.bulk_inserter_capacity_bonus = 11
  end)

  after_all(function()
    game.forces.player.bulk_inserter_capacity_bonus = saved_bonus
  end)

  ---@type {[1]: integer, [2]: integer}[]
  local RATIOS = { { 2, 3 }, { 3, 5 } }
  for _, r in ipairs(RATIOS) do
    local n, m = r[1], r[2]
    local tag = n .. "_" .. m

    test("f8_free_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, recirc = true })
      H.measure(counts(rig), WARMUP, WINDOW, function(rates)
        H.report("F8 free %d:%d: outputs %s, total %.3f (plain network: %.3f)", n, m, fmt(rates), H.sum(rates), math.min(n, m) * RATE)
        H.assert_equal(rates, "output")
        near(H.sum(rates), math.min(n, m) * RATE, "total")
        assert_conserved(rig, "free")
        done()
      end)
    end)

    test("f8_unequal_inputs_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, recirc = true, feed = { "slow" } })
      H.measure(counts(rig), WARMUP, WINDOW, function(rates)
        local supply = RATE / 3 + (n - 1) * RATE
        H.report("F8 unequal inputs %d:%d (input 1 at a third): outputs %s, total %.3f (supply %.3f)", n, m, fmt(rates), H.sum(rates), supply)
        H.assert_equal(rates, "output")
        near(H.sum(rates), supply, "total")
        assert_conserved(rig, "unequal inputs")
        done()
      end)
    end)

    test("f8_slow_belt_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, recirc = true, sinks = { "basic" } })
      H.measure(counts(rig), WARMUP, WINDOW, function(rates)
        local rest = { table.unpack(rates, 2, m) }
        local expected = (n * RATE - RATE / 3) / (m - 1)
        H.report("F8 slow belt %d:%d (output 1 at 15): output 1 %.3f, others %s (expected %.3f each), total %.3f",
          n, m, rates[1], fmt(rest), expected, H.sum(rates))
        near(rates[1], RATE / 3, "slow output")
        H.assert_equal(rest, "other output")
        near(H.sum(rest) / (m - 1), expected, "other outputs")
        near(H.sum(rates), n * RATE, "total")
        assert_conserved(rig, "slow belt")
        done()
      end)
    end)

    test("f8_slow_port_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, port = 1, recirc = true })
      rig.inserters[1].disabled_by_script = true
      rig.inserters[2].disabled_by_script = true
      rig.inserters[3].inserter_stack_size_override = 1
      H.measure(counts(rig), WARMUP, WINDOW, function(rates)
        local belts = { table.unpack(rates, 1, m) }
        local port = rates[m + 1]
        H.report("F8 slow port %d:%d: belt outputs %s (expected %.3f each), port %.3f, total %.3f",
          n, m, fmt(belts), (n * RATE - port) / m, port, H.sum(rates))
        H.assert_equal(belts, "belt output")
        near(H.sum(rates), n * RATE, "belts plus port")
        assert_conserved(rig, "slow port")
        done()
      end)
    end)

    -- Throughput unlimited: block all but two outputs; those two still get a full belt each.
    test("f8_blocked_outputs_" .. tag, function()
      async(WARMUP + WINDOW + 300)
      local rig = H.rig({ n = n, m = m, recirc = true })
      for j = 3, m do
        rig.sink_loaders[j].disabled_by_script = true
      end
      local function with_draw()
        local c = counts(rig)()
        for i = 1, n do
          c[m + i] = H.drawn(rig, i)
        end
        return c
      end
      H.measure(with_draw, WARMUP, WINDOW, function(rates)
        -- Recorded, not asserted: with recirculation the loop inputs compete with the real
        -- inputs, so the draw is not equal when the open outputs cannot take everything
        -- (flow model: 3:5 draws 45 / 33.75 / 33.75). See docs/feasibility.md F8.
        H.report("F8 blocked outputs %d:%d (only 1 and 2 open): outputs %s, inputs drawn %s", n, m,
          fmt({ table.unpack(rates, 1, m) }), fmt({ table.unpack(rates, m + 1, m + n) }))
        near(rates[1], RATE, "open output 1")
        near(rates[2], RATE, "open output 2")
        assert_conserved(rig, "blocked outputs")
        done()
      end)
    end)
  end
end)
