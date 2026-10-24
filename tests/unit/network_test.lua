local network = require("scripts.network")
local flow = require("scripts.flow")

local EPS = 1e-9

local function near(a, b)
  return math.abs(a - b) <= EPS
end

-- Ratios checked by outputs_are_equal and inputs_are_drawn_equally.
local function balance_ratios()
  local list = {}
  for n = 1, 8 do
    for m = 1, 8 do
      list[#list + 1] = { n, m }
    end
  end
  list[#list + 1] = { 16, 16 }
  list[#list + 1] = { 3, 16 }
  list[#list + 1] = { 16, 3 }
  return list
end

local function build(n, m, opts)
  local net, err = network.build(n, m, opts)
  assert(net, string.format("%d:%d does not build: %s", n, m, tostring(err)))
  return net
end

local function check_outputs_equal(net)
  local n, m = net.n_in, net.n_out
  local expected = math.min(n, m) / m
  local shares = flow.shares(net)
  assert(#shares == m, string.format("%d:%d: %d shares", n, m, #shares))
  for j = 1, m do
    assert(
      near(shares[j], expected),
      string.format("%d:%d output %d gets %.15g, expected %.15g", n, m, j, shares[j], expected)
    )
  end
end

local function check_inputs_equal(net, cap)
  local n, m = net.n_in, net.n_out
  local draw = flow.input_draw(net, cap)
  local expected = math.min(1, cap * m / n)
  for i = 1, n do
    assert(
      near(draw[i], expected),
      string.format("%d:%d cap %g: input %d draws %.15g, expected %.15g", n, m, cap, i, draw[i], expected)
    )
  end
end

-- Subsets of 1..k as bit masks.
local function subset(mask, k)
  local list = {}
  for i = 1, k do
    if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
      list[#list + 1] = i
    end
  end
  return list
end

local function check_throughput(net, ins, outs)
  local expected = math.min(#ins, #outs)
  local t = flow.max_throughput(net, ins, outs)
  assert(
    near(t, expected),
    string.format(
      "%d:%d ins {%s} outs {%s}: max throughput %.15g, expected %d",
      net.n_in,
      net.n_out,
      table.concat(ins, ","),
      table.concat(outs, ","),
      t,
      expected
    )
  )
end

-- Same subsets in the splitter model (not just a routing): feed only `ins`, open only `outs`.
local function check_model_throughput(net, ins, outs)
  local supply, demand = {}, {}
  for i = 1, net.n_in do
    supply[i] = 0
  end
  for j = 1, net.n_out do
    demand[j] = 0
  end
  for _, i in ipairs(ins) do
    supply[i] = 1
  end
  for _, j in ipairs(outs) do
    demand[j] = 1
  end
  local state = flow.solve(net, supply, demand)
  local total = 0
  for _, j in ipairs(outs) do
    total = total + state.f[state.out_edge[j]]
  end
  local expected = math.min(#ins, #outs)
  assert(
    near(total, expected),
    string.format(
      "%d:%d ins {%s} outs {%s}: splitter model moves %.15g, expected %d",
      net.n_in,
      net.n_out,
      table.concat(ins, ","),
      table.concat(outs, ","),
      total,
      expected
    )
  )
end

-- Deterministic LCG (portable, unlike math.random across C libraries).
local function lcg(seed)
  local state = seed
  return function(k)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % k
  end
end

-- Every subset pair when n, m <= limit (default 6), else `samples` (default 200) random
-- pairs with a fixed seed.
local function each_subset_pair(n, m, fn, limit, samples)
  limit = limit or 6
  if n <= limit and m <= limit then
    for a = 1, 2 ^ n - 1 do
      for b = 1, 2 ^ m - 1 do
        fn(subset(a, n), subset(b, m))
      end
    end
  else
    local rand = lcg(20261024 + 100 * n + m)
    for _ = 1, samples or 200 do
      fn(subset(1 + rand(2 ^ n - 1), n), subset(1 + rand(2 ^ m - 1), m))
    end
  end
end

local function check_structure(net)
  local seen = {}
  local function use(p, dir)
    local key = string.format("%s:%d:%d:%s", p.kind, p.id, p.port or 1, dir)
    assert(not seen[key], "port used twice: " .. key)
    seen[key] = true
  end
  local ids = {}
  for _, s in ipairs(net.splitters) do
    assert(not ids[s.id], "duplicate splitter id " .. s.id)
    ids[s.id] = true
  end
  for _, ed in ipairs(net.edges) do
    assert(ed.from.kind ~= "out" and ed.to.kind ~= "in", "edge direction")
    if ed.from.kind == "splitter" then
      assert(ids[ed.from.id], "edge from unknown splitter")
    end
    if ed.to.kind == "splitter" then
      assert(ids[ed.to.id], "edge to unknown splitter")
    end
    use(ed.from, "out")
    use(ed.to, "in")
  end
  for i = 1, net.n_in do
    assert(seen["in:" .. i .. ":1:out"], "input " .. i .. " unconnected")
  end
  for j = 1, net.n_out do
    assert(seen["out:" .. j .. ":1:in"], "output " .. j .. " unconnected")
  end
  -- Every splitter has at least one input and one output; at most one dead port.
  for _, s in ipairs(net.splitters) do
    local ports = 0
    for _, key in ipairs({ ":1:in", ":2:in", ":1:out", ":2:out" }) do
      if seen["splitter:" .. s.id .. key] then
        ports = ports + 1
      end
    end
    assert(ports >= 3, "splitter " .. s.id .. " has " .. ports .. " connected ports")
  end
  -- Every node is reachable from an input and reaches an output (nothing trapped).
  local function key(p)
    return p.kind == "in" and "in" or p.kind == "out" and "out" or (p.kind .. ":" .. p.id)
  end
  local function reach(start, forward)
    local seen_nodes, changed = { [start] = true }, true
    while changed do
      changed = false
      for _, ed in ipairs(net.edges) do
        local a, b = key(ed.from), key(ed.to)
        if not forward then
          a, b = b, a
        end
        if seen_nodes[a] and not seen_nodes[b] then
          seen_nodes[b], changed = true, true
        end
      end
    end
    return seen_nodes
  end
  local from_in, to_out = reach("in", true), reach("out", false)
  for _, s in ipairs(net.splitters) do
    assert(from_in["splitter:" .. s.id], "splitter " .. s.id .. " unreachable from the inputs")
    assert(to_out["splitter:" .. s.id], "splitter " .. s.id .. " reaches no output")
  end
end

local function all_checks(n, m)
  local net = build(n, m)
  check_structure(net)
  check_outputs_equal(net)
  check_inputs_equal(net, 0.5)
  each_subset_pair(n, m, function(ins, outs)
    check_throughput(net, ins, outs)
  end)
end

return {
  outputs_are_equal = function()
    for _, r in ipairs(balance_ratios()) do
      check_outputs_equal(build(r[1], r[2]))
    end
  end,

  inputs_are_drawn_equally = function()
    for _, r in ipairs(balance_ratios()) do
      check_inputs_equal(build(r[1], r[2]), 0.5)
    end
  end,

  inputs_are_drawn_equally_at_other_capacities = function()
    for _, r in ipairs(balance_ratios()) do
      local net = build(r[1], r[2])
      for _, cap in ipairs({ 0.1, 0.25, 0.75, 0.9, 0.99 }) do
        check_inputs_equal(net, cap)
      end
    end
  end,

  -- Beyond the plan: uneven input supply (outputs open) still gives equal outputs, and
  -- uneven output demand (inputs saturated) still draws inputs equally.
  uneven_supply_and_demand_stay_balanced = function()
    local rand = lcg(4242)
    for _, r in ipairs(balance_ratios()) do
      local n, m = r[1], r[2]
      local net = build(n, m)
      for _ = 1, 2 do
        local supply, demand, ones_in, ones_out, total_s, total_d = {}, {}, {}, {}, 0, 0
        for i = 1, n do
          supply[i] = rand(1000) / 1000
          total_s = total_s + supply[i]
          ones_in[i] = 1
        end
        for j = 1, m do
          demand[j] = rand(1000) / 1000
          total_d = total_d + demand[j]
          ones_out[j] = 1
        end
        if total_s <= m then
          local state = flow.solve(net, supply, ones_out)
          for j = 1, m do
            local f = state.f[state.out_edge[j]]
            assert(near(f, total_s / m), string.format("%d:%d uneven supply: output %d gets %.15g", n, m, j, f))
          end
        end
        if total_d <= n then
          local state = flow.solve(net, ones_in, demand)
          for i = 1, n do
            local f = state.f[state.in_edge[i]]
            assert(near(f, total_d / n), string.format("%d:%d uneven demand: input %d draws %.15g", n, m, i, f))
          end
        end
      end
    end
  end,

  throughput_unlimited = function()
    for n = 1, 8 do
      for m = 1, 8 do
        local net = build(n, m)
        each_subset_pair(n, m, function(ins, outs)
          check_throughput(net, ins, outs)
        end)
      end
    end
  end,

  -- Max flow ignores how splitters share capacity with loops; this runs the same subsets
  -- through the splitter model (exhaustive up to 4:4, sampled above).
  throughput_unlimited_in_the_splitter_model = function()
    local ratios = {}
    for n = 1, 8 do
      for m = 1, 8 do
        ratios[#ratios + 1] = { n, m }
      end
    end
    ratios[#ratios + 1] = { 16, 16 }
    ratios[#ratios + 1] = { 3, 16 }
    ratios[#ratios + 1] = { 16, 3 }
    for _, r in ipairs(ratios) do
      local net = build(r[1], r[2])
      each_subset_pair(r[1], r[2], function(ins, outs)
        check_model_throughput(net, ins, outs)
      end, 4, 25)
    end
  end,

  structure_is_well_formed = function()
    for _, r in ipairs(balance_ratios()) do
      check_structure(build(r[1], r[2]))
      check_structure(build(r[1], r[2], { balance_lanes = true }))
    end
  end,

  degenerate_ratios_build = function()
    all_checks(1, 1)
    all_checks(1, 8)
    all_checks(8, 1)
    local one = build(1, 1)
    assert(#one.splitters == 0 and #one.edges == 1, "1:1 is a single edge")
    assert(#build(2, 2).splitters == 1, "2:2 is one splitter")
    assert(#build(1, 2).splitters == 1 and #build(2, 1).splitters == 1, "1:2 and 2:1 are one splitter")
  end,

  loops_drain_after_backpressure = function()
    for _, r in ipairs({ { 3, 5 }, { 5, 3 }, { 2, 3 } }) do
      local net = build(r[1], r[2])
      local draw, blocked = flow.input_draw(net, 0)
      local total = 0
      for i = 1, #draw do
        total = total + draw[i]
      end
      assert(near(total, 0), string.format("%d:%d blocked still draws %.15g", r[1], r[2], total))
      for e = 1, #net.edges do
        assert(near(blocked.f[e], 0), string.format("%d:%d edge %d circulates while blocked", r[1], r[2], e))
      end
      local fresh = flow.shares(net)
      local after = flow.shares(net, blocked)
      for j = 1, net.n_out do
        assert(near(after[j], fresh[j]), string.format("%d:%d output %d changed after release", r[1], r[2], j))
        assert(near(after[j], math.min(r[1], r[2]) / r[2]), "exact after release")
      end
    end
  end,

  -- From the loops-full state (every supply 1, every demand 0: the greatest fixed point)
  -- the network's input and output flows equal those from the default empty start.
  loops_full_start_gives_the_same_flows = function()
    for _, r in ipairs(balance_ratios()) do
      local n, m = r[1], r[2]
      local net = build(n, m)
      local full = { s = {}, d = {} }
      for e = 1, #net.edges do
        full.s[e], full.d[e] = 1, 0
      end
      local ones = {}
      for i = 1, n do
        ones[i] = 1
      end
      for _, cap in ipairs({ 1, 0.5 }) do
        local caps = {}
        for j = 1, m do
          caps[j] = cap
        end
        local a = flow.solve(net, ones, caps)
        local b = flow.solve(net, ones, caps, full)
        for i = 1, n do
          local x, y = a.f[a.in_edge[i]], b.f[b.in_edge[i]]
          assert(near(x, y), string.format("%d:%d cap %g input %d: %.15g vs %.15g", n, m, cap, i, x, y))
        end
        for j = 1, m do
          local x, y = a.f[a.out_edge[j]], b.f[b.out_edge[j]]
          assert(near(x, y), string.format("%d:%d cap %g output %d: %.15g vs %.15g", n, m, cap, j, x, y))
        end
      end
    end
  end,

  size_limit_is_explicit = function()
    local net, err = network.build(17, 2)
    assert(net == nil and err == "too-large", "17:2 must be refused")
    net, err = network.build(2, 17)
    assert(net == nil and err == "too-large", "2:17 must be refused")
    net, err = network.build(0, 2)
    assert(net == nil and err == "invalid", "0:2 must be refused")
    assert(network.build(16, 16), "16:16 must build")
  end,

  build_is_deterministic = function()
    local a, b = build(5, 3), build(5, 3)
    assert(#a.edges == #b.edges, "same edge count")
    for e = 1, #a.edges do
      local x, y = a.edges[e], b.edges[e]
      assert(
        x.from.kind == y.from.kind and x.from.id == y.from.id and x.from.port == y.from.port,
        "same edges"
      )
      assert(x.to.kind == y.to.kind and x.to.id == y.to.id and x.to.port == y.to.port, "same edges")
    end
  end,

  balance_lanes_adds_lane_splitters = function()
    for _, r in ipairs(balance_ratios()) do
      local n, m = r[1], r[2]
      local plain = build(n, m)
      local net = build(n, m, { balance_lanes = true })
      assert(plain.lane_splitters == nil, "no lane splitters without opts")
      assert(#net.lane_splitters == n, string.format("%d:%d has %d lane splitters", n, m, #net.lane_splitters))
      assert(#net.splitters == #plain.splitters, "same splitters")
      for _, l in ipairs(net.lane_splitters) do
        assert(l.kind == "lane_splitter", "lane splitter kind")
      end
      -- Each lane splitter sits directly on an input.
      for _, ed in ipairs(net.edges) do
        if ed.to.kind == "lane_splitter" then
          assert(ed.from.kind == "in", "lane splitter right after an input")
        end
      end
      check_outputs_equal(net)
      check_inputs_equal(net, 0.5)
    end
  end,

  -- Lane-aware model: with only the left lanes fed (0.5 belt each), every output lane gets
  -- the same and the total is min(N / 2, M). Output-side lane splitters fail this for
  -- N > M (each output's lanes only bring 0.5).
  balance_lanes_keeps_full_throughput_with_one_lane_fed = function()
    for _, r in ipairs(balance_ratios()) do
      local n, m = r[1], r[2]
      local net = build(n, m, { balance_lanes = true })
      local left, right = {}, {}
      for i = 1, n do
        left[i], right[i] = 0.5, 0
      end
      local lanes = flow.solve_lanes(net, left, right, 1)
      local per_lane = math.min(n / 2, m) / (2 * m)
      for j = 1, m do
        local o = assert(lanes.out[j], "missing output")
        assert(
          near(o.left, per_lane) and near(o.right, per_lane),
          string.format("%d:%d output %d lanes %.15g / %.15g, expected %.15g", n, m, j, o.left, o.right, per_lane)
        )
      end
      for i = 1, n do
        assert(near(lanes.draw[i], math.min(0.5, m / n)), string.format("%d:%d input %d draw", n, m, i))
      end
    end
  end,

  -- Without balance_lanes the network keeps lanes: one lane in, the same lane out.
  plain_network_keeps_lanes = function()
    for _, r in ipairs(balance_ratios()) do
      local n, m = r[1], r[2]
      local left, right = {}, {}
      for i = 1, n do
        left[i], right[i] = 0.5, 0
      end
      local lanes = flow.solve_lanes(build(n, m), left, right, 1)
      for j = 1, m do
        local o = assert(lanes.out[j], "missing output")
        assert(near(o.right, 0), string.format("%d:%d output %d right lane not empty", n, m, j))
        assert(near(o.left, math.min(n, m) / (2 * m)), string.format("%d:%d output %d left lane", n, m, j))
      end
    end
  end,

  splitter_count_is_reported = function()
    local parts = {}
    for _, r in ipairs({ { 2, 3 }, { 3, 5 }, { 8, 3 }, { 1, 5 }, { 16, 16 } }) do
      local net = build(r[1], r[2])
      parts[#parts + 1] = string.format("%d:%d=%d", r[1], r[2], #net.splitters)
    end
    print("  splitter counts: " .. table.concat(parts, " "))
  end,
}
