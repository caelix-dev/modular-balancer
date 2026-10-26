local network = require("scripts.network")
local flow = require("scripts.flow")

local EPS = 1e-9

local function near(a, b)
  return math.abs(a - b) <= EPS
end

-- Deterministic LCG (portable, unlike math.random across C libraries).
local function lcg(seed)
  local state = seed
  return function(k)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % k
  end
end

-- Exhaustive set: every 1 <= n, m <= 8, plus 16:16, 3:16 and 16:3.
local function exhaustive_ratios()
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

-- Sampled set: 40 seeded ratios with max(n, m) in 17..64, plus the size-jump cases.
local function sampled_ratios()
  local rand = lcg(25102026)
  local list = {}
  for _ = 1, 40 do
    local big = 17 + rand(48)
    local other = 1 + rand(big)
    if rand(2) == 0 then
      list[#list + 1] = { big, other }
    else
      list[#list + 1] = { other, big }
    end
  end
  for _, r in ipairs({ { 9, 1 }, { 17, 2 }, { 33, 5 }, { 1, 40 }, { 100, 3 } }) do
    list[#list + 1] = r
  end
  return list
end

local function build(n, m, opts)
  local net, err = network.build(n, m, opts)
  assert(net, string.format("%d:%d does not build: %s", n, m, tostring(err)))
  return net
end

local function tag(net)
  return string.format("%d:%d", net.n_in, net.n_out)
end

---@param k integer
---@param v number
---@return number[]
local function filled(k, v)
  local t = {}
  for i = 1, k do
    t[i] = v
  end
  return t
end

local function outputs_of(state, m)
  local o = {}
  for j = 1, m do
    o[j] = state.f[state.out_edge[j]]
  end
  return o
end

local function inputs_of(state, n)
  local d = {}
  for i = 1, n do
    d[i] = state.f[state.in_edge[i]]
  end
  return d
end

-- Water filling: the level x with sum(min(cap_j, x)) = min(total, sum(cap_j)). Returns
-- what each output gets.
local function water_fill(caps, total)
  local sorted = {}
  local sum = 0
  for j, c in ipairs(caps) do
    sorted[j] = c
    sum = sum + c
  end
  table.sort(sorted)
  ---@type number
  local left = math.min(total, sum)
  local rest = #sorted
  ---@type number
  local level = 0
  for _, c in ipairs(sorted) do
    if c * rest >= left then
      level = left / rest
      break
    end
    left, rest = left - c, rest - 1
    level = c
  end
  local got = {}
  for j, c in ipairs(caps) do
    got[j] = math.min(c, level)
  end
  return got
end

local function assert_values(got, expected, what)
  for j = 1, #expected do
    assert(near(got[j], expected[j]), string.format("%s: [%d] = %.15g, expected %.15g", what, j, got[j], expected[j]))
  end
end

local function random_subset(k, rand)
  local list = {}
  while #list == 0 do
    for i = 1, k do
      if rand(2) == 0 then
        list[#list + 1] = i
      end
    end
  end
  return list
end

local function each_subset_pair(n, m, fn, limit, samples, rand)
  if n <= limit and m <= limit then
    for a = 1, 2 ^ n - 1 do
      for b = 1, 2 ^ m - 1 do
        local ins, outs = {}, {}
        for i = 1, n do
          if math.floor(a / 2 ^ (i - 1)) % 2 == 1 then
            ins[#ins + 1] = i
          end
        end
        for j = 1, m do
          if math.floor(b / 2 ^ (j - 1)) % 2 == 1 then
            outs[#outs + 1] = j
          end
        end
        fn(ins, outs)
      end
    end
  else
    rand = rand or lcg(20261024 + 100 * n + m)
    for _ = 1, samples do
      fn(random_subset(n, rand), random_subset(m, rand))
    end
  end
end

---------------------------------------------------------------------------------------------
-- Checks. Each takes a network; `level` is "full" (exhaustive set) or "sampled".

local function check_outputs_equal(net)
  local n, m = net.n_in, net.n_out
  local shares = flow.shares(net)
  assert(#shares == m, tag(net) .. ": " .. #shares .. " shares")
  assert_values(shares, filled(m, math.min(n, m) / m), tag(net) .. " shares")
end

local function check_inputs_equal(net, cap)
  local n, m = net.n_in, net.n_out
  local draw = flow.input_draw(net, cap)
  assert_values(draw, filled(n, math.min(1, cap * m / n)), tag(net) .. " cap " .. cap .. " draw")
end

local function check_throughput(net, ins, outs)
  local t = flow.max_throughput(net, ins, outs)
  assert(
    near(t, math.min(#ins, #outs)),
    string.format("%s ins {%s} outs {%s}: max flow %.15g", tag(net), table.concat(ins, ","), table.concat(outs, ","), t)
  )
end

-- Subsets through the splitter model (not just a routing): feed only `ins`, open only
-- `outs`. Also from the loops-full start.
local function check_model_throughput(net, ins, outs, init)
  local supply, demand = filled(net.n_in, 0), filled(net.n_out, 0)
  for _, i in ipairs(ins) do
    supply[i] = 1
  end
  for _, j in ipairs(outs) do
    demand[j] = 1
  end
  local state = flow.solve(net, supply, demand, init)
  local total = 0
  for _, j in ipairs(outs) do
    total = total + state.f[state.out_edge[j]]
  end
  assert(
    near(total, math.min(#ins, #outs)),
    string.format(
      "%s ins {%s} outs {%s}: splitter model moves %.15g",
      tag(net),
      table.concat(ins, ","),
      table.concat(outs, ","),
      total
    )
  )
end

local function loops_full(net)
  local full = { s = {}, d = {} }
  for e = 1, #net.edges do
    full.s[e], full.d[e] = 1, 0
  end
  return full
end

-- Solves from the default (empty) start and from the loops-full start; calls
-- check(state, label) for both.
local function solve_both(net, supply, demand, check)
  check(flow.solve(net, supply, demand), "empty start")
  check(flow.solve(net, supply, demand, loops_full(net)), "loops-full start")
end

-- Any input mix, outputs unbounded: every input alone gives each output 1/m of it, and
-- random rate vectors give equal outputs totalling min(sum, m).
local function check_any_input_mix(net, rand, mixes, alone)
  local n, m = net.n_in, net.n_out
  local open = filled(m, 1)
  local function check(supply, label)
    local total = 0
    for i = 1, n do
      total = total + supply[i]
    end
    local state = flow.solve(net, supply, open)
    assert_values(outputs_of(state, m), filled(m, math.min(total, m) / m), tag(net) .. " " .. label)
  end
  for a = 1, math.min(n, alone) do
    local supply = filled(n, 0)
    supply[a] = 1
    check(supply, "input " .. a .. " alone")
  end
  for k = 1, mixes do
    local supply = {}
    for i = 1, n do
      supply[i] = rand(1001) / 1000
    end
    check(supply, "random mix " .. k)
  end
end

-- Lane-aware, with balance_lanes. Each lane of every input alone and random lane rates give
-- equal lanes on every output, totalling min(supply, m), and draw every input's lanes in
-- full; all left lanes fed draws min(0.5, m / n) per input. Then one slow output: both lanes
-- of every output water-fill (each lane network gets half of everything).
-- `plain`: no slow-output cases (a plain network has no recirculation, so a slow output's share
-- goes to its sibling and the shares are not water-filled).
local function check_lanes(lnet, rand, mixes, alone, plain)
  local n, m = lnet.n_in, lnet.n_out
  local function check(left, right, label, caps)
    local total = 0
    for i = 1, n do
      total = total + left[i] + right[i]
    end
    caps = caps or filled(m, 1)
    local half_caps = {}
    for j = 1, m do
      half_caps[j] = caps[j] / 2
    end
    local expected = water_fill(half_caps, total / 2)
    local lanes = flow.solve_lanes(lnet, left, right, caps)
    for j = 1, m do
      local o = assert(lanes.out[j], "missing output")
      assert(
        near(o.left, expected[j]) and near(o.right, expected[j]),
        string.format("%s lanes %s: output %d %.15g / %.15g, expected %.15g", tag(lnet), label, j, o.left, o.right, expected[j])
      )
    end
    return lanes
  end
  local zero = filled(n, 0)
  local lanes = check(filled(n, 0.5), zero, "all left lanes")
  assert_values(lanes.draw, filled(n, math.min(0.5, m / n)), tag(lnet) .. " lanes all left lanes, draw")
  for a = 1, math.min(n, alone) do
    local one = filled(n, 0)
    one[a] = 0.5
    check(one, zero, "left lane of input " .. a .. " alone")
    check(zero, one, "right lane of input " .. a .. " alone")
  end
  for k = 1, mixes do
    local left, right = {}, {}
    for i = 1, n do
      left[i], right[i] = rand(501) / 1000, rand(501) / 1000
    end
    local caps = nil
    if k % 2 == 0 and m >= 2 and not plain then
      caps = filled(m, 1)
      caps[1 + rand(m)] = rand(1001) / 1000
    end
    check(left, right, "random mix " .. k .. (caps and " with a slow output" or ""), caps)
  end
end

-- From the loops-full state the network's input and output flows equal the default start.
local function check_loops_full_start(net)
  local n, m = net.n_in, net.n_out
  local full = loops_full(net)
  for _, cap in ipairs({ 1, 0.5 }) do
    local a = flow.solve(net, filled(n, 1), filled(m, cap))
    local b = flow.solve(net, filled(n, 1), filled(m, cap), full)
    assert_values(inputs_of(b, n), inputs_of(a, n), tag(net) .. " loops-full start, cap " .. cap .. ", inputs")
    assert_values(outputs_of(b, m), outputs_of(a, m), tag(net) .. " loops-full start, cap " .. cap .. ", outputs")
  end
end

-- One output limited to 0.3 of its share: it gets that, every other output gets
-- (total - 0.3 * share) / (m - 1). With all inputs full, and with a random input mix.
local function check_one_slow_output(net, rand, cases)
  local n, m = net.n_in, net.n_out
  if m < 2 then
    return
  end
  for k = 1, cases do
    local supply = filled(n, 1)
    if k > 1 then
      for i = 1, n do
        supply[i] = rand(1001) / 1000
      end
    end
    ---@type number
    local supplied = 0
    for i = 1, n do
      supplied = supplied + (supply[i] or 0)
    end
    local share = math.min(supplied, m) / m
    local slow = 1 + rand(m)
    local caps = filled(m, 1)
    caps[slow] = 0.3 * share
    local total = math.min(supplied, 0.3 * share + (m - 1))
    local expected = filled(m, (total - 0.3 * share) / (m - 1))
    expected[slow] = 0.3 * share
    solve_both(net, supply, caps, function(state, start)
      assert_values(outputs_of(state, m), expected, tag(net) .. " slow output " .. slow .. " (case " .. k .. ", " .. start .. ")")
    end)
  end
end

-- Random subsets of outputs with random limits: water filling (every unlimited output
-- equal, every limited one gets min(limit, level)).
local function check_slow_subsets(net, rand, cases)
  local n, m = net.n_in, net.n_out
  for k = 1, cases do
    local supply = filled(n, 1)
    if k % 2 == 0 then
      for i = 1, n do
        supply[i] = rand(1001) / 1000
      end
    end
    ---@type number
    local supplied = 0
    for i = 1, n do
      supplied = supplied + (supply[i] or 0)
    end
    local caps = filled(m, 1)
    for _, j in ipairs(random_subset(m, rand)) do
      caps[j] = rand(1001) / 1000
    end
    local expected = water_fill(caps, supplied)
    solve_both(net, supply, caps, function(state, start)
      assert_values(outputs_of(state, m), expected, tag(net) .. " slow subset (case " .. k .. ", " .. start .. ")")
    end)
  end
end

-- Inputs saturated: every output limited to the same value (0.1, 0.9; inputs_are_drawn_equally
-- runs the others), only a random subset open, or random uneven limits on every output. Each
-- input draws min(n, sum of limits) / n, from both start states.
local function check_draw_under_backpressure(net, rand, cases)
  local n, m = net.n_in, net.n_out
  local function check(caps, label)
    local sum = 0
    for j = 1, m do
      sum = sum + caps[j]
    end
    local expected = filled(n, math.min(n, sum) / n)
    solve_both(net, filled(n, 1), caps, function(state, start)
      assert_values(inputs_of(state, n), expected, tag(net) .. " " .. label .. ", " .. start)
    end)
  end
  for _, cap in ipairs({ 0.1, 0.9 }) do
    check(filled(m, cap), "every output at " .. cap)
  end
  for k = 1, cases do
    local open = random_subset(m, rand)
    local caps = filled(m, 0)
    for _, j in ipairs(open) do
      caps[j] = 1
    end
    check(caps, "only {" .. table.concat(open, ",") .. "} open (case " .. k .. ")")
    local uneven = {}
    for j = 1, m do
      uneven[j] = rand(1001) / 1000
    end
    check(uneven, "uneven limits (case " .. k .. ")")
  end
end

local function check_structure(net)
  local seen = {}
  local function use(p, dir)
    local key = string.format("%s:%d:%d:%s", p.kind, p.id, p.port or 1, dir)
    assert(not seen[key], tag(net) .. " port used twice: " .. key)
    seen[key] = true
  end
  ---@type table<string, table<integer, boolean>>
  local ids = { splitter = {}, priority = {} }
  for _, s in ipairs(net.splitters) do
    assert(not ids.splitter[s.id], "duplicate splitter id " .. s.id)
    ids.splitter[s.id] = true
  end
  for _, p in ipairs(net.priority) do
    assert(p.kind == "priority", "priority node kind")
    assert(not ids.priority[p.id], "duplicate priority id " .. p.id)
    ids.priority[p.id] = true
  end
  for _, ed in ipairs(net.edges) do
    assert(ed.from.kind ~= "out" and ed.to.kind ~= "in", "edge direction")
    for _, p in ipairs({ ed.from, ed.to }) do
      local set = ids[p.kind] --[[@as table<integer, boolean>?]]
      if set then
        assert(set[p.id], tag(net) .. " edge to unknown " .. p.kind .. " " .. p.id)
      end
    end
    use(ed.from, "out")
    use(ed.to, "in")
    if ed.from.kind == "priority" then
      -- Port 1 is a network output, port 2 the overflow back into the network.
      if ed.from.port == 1 then
        assert(ed.to.kind == "out", tag(net) .. " priority port 1 must be a network output")
      else
        assert(ed.to.kind ~= "out", tag(net) .. " priority port 2 must go back into the network")
      end
    end
  end
  for i = 1, net.n_in do
    assert(seen["in:" .. i .. ":1:out"], "input " .. i .. " unconnected")
  end
  for j = 1, net.n_out do
    assert(seen["out:" .. j .. ":1:in"], "output " .. j .. " unconnected")
  end
  for kind, set in pairs(ids) do
    for id in pairs(set) do
      local ports = 0
      for _, key in ipairs({ ":1:in", ":2:in", ":1:out", ":2:out" }) do
        if seen[kind .. ":" .. id .. key] then
          ports = ports + 1
        end
      end
      assert(ports >= 3, tag(net) .. " " .. kind .. " " .. id .. " has " .. ports .. " connected ports")
    end
  end
  -- Every node is reachable from an input and reaches an output (nothing trapped).
  local function key(p)
    return (p.kind == "in" or p.kind == "out") and p.kind or (p.kind .. ":" .. p.id)
  end
  local succ, pred = {}, {}
  for _, ed in ipairs(net.edges) do
    local a, b = key(ed.from), key(ed.to)
    succ[a] = succ[a] or {}
    table.insert(succ[a], b)
    pred[b] = pred[b] or {}
    table.insert(pred[b], a)
  end
  local function reach(start, forward)
    local adj = forward and succ or pred
    local seen_nodes, queue, qi = { [start] = true }, { start }, 1
    while qi <= #queue do
      local a = queue[qi]
      qi = qi + 1
      for _, b in ipairs(adj[a] or {}) do
        if not seen_nodes[b] then
          seen_nodes[b] = true
          queue[#queue + 1] = b
        end
      end
    end
    return seen_nodes
  end
  local from_in, to_out = reach("in", true), reach("out", false)
  for kind, set in pairs(ids) do
    for id in pairs(set) do
      assert(from_in[kind .. ":" .. id], tag(net) .. " " .. kind .. " " .. id .. " unreachable from the inputs")
      assert(to_out[kind .. ":" .. id], tag(net) .. " " .. kind .. " " .. id .. " reaches no output")
    end
  end
  local st = net.stats
  assert(
    st.splitters == #net.splitters
      and st.priority == #net.priority
      and st.lane_splitters == #(net.lane_splitters or {})
      and st.edges == #net.edges,
    tag(net) .. " stats"
  )
end

local function for_each(ratios, fn)
  for _, r in ipairs(ratios) do
    fn(build(r[1], r[2]), r[1], r[2])
  end
end

-- Both modes: recirculating (the default) and plain (recirc = false, a per-balancer setting).
-- Every guarantee except recirculation itself holds in both.
local MODES = { {}, { recirc = false } }
local function for_each_mode(ratios, fn)
  for _, opts in ipairs(MODES) do
    for _, r in ipairs(ratios) do
      fn(build(r[1], r[2], opts), r[1], r[2])
    end
  end
end

---------------------------------------------------------------------------------------------

return {
  outputs_are_equal = function()
    for_each_mode(exhaustive_ratios(), check_outputs_equal)
    for_each_mode(sampled_ratios(), check_outputs_equal)
  end,

  inputs_are_drawn_equally = function()
    for _, ratios in ipairs({ exhaustive_ratios(), sampled_ratios() }) do
      for_each_mode(ratios, function(net)
        for _, cap in ipairs({ 0.25, 0.5, 0.75, 0.99 }) do
          check_inputs_equal(net, cap)
        end
      end)
    end
  end,

  throughput_unlimited = function()
    for _, opts in ipairs(MODES) do
      for n = 1, 8 do
        for m = 1, 8 do
          local net = build(n, m, opts)
          each_subset_pair(n, m, function(ins, outs)
            check_throughput(net, ins, outs)
          end, 6, 200)
        end
      end
    end
    for_each_mode(sampled_ratios(), function(net, n, m)
      each_subset_pair(n, m, function(ins, outs)
        check_throughput(net, ins, outs)
      end, 0, 20)
    end)
  end,

  -- Max flow ignores how splitters share capacity with loops; this runs subsets through the
  -- splitter model, from the empty and from the loops-full start (exhaustive up to 4:4).
  throughput_unlimited_in_the_splitter_model = function()
    for_each_mode(exhaustive_ratios(), function(net, n, m)
      local full = loops_full(net)
      each_subset_pair(n, m, function(ins, outs)
        check_model_throughput(net, ins, outs)
        check_model_throughput(net, ins, outs, full)
      end, 4, 25)
    end)
    for_each_mode(sampled_ratios(), function(net, n, m)
      each_subset_pair(n, m, function(ins, outs)
        check_model_throughput(net, ins, outs)
      end, 0, 6)
    end)
  end,

  outputs_equal_for_any_input_mix = function()
    local rand = lcg(777)
    for_each_mode(exhaustive_ratios(), function(net)
      check_any_input_mix(net, rand, 50, math.huge)
    end)
    for_each_mode(sampled_ratios(), function(net)
      check_any_input_mix(net, rand, 8, 2)
    end)
  end,

  balance_lanes_lane_aware = function()
    local rand = lcg(4242)
    for _, entry in ipairs({ { exhaustive_ratios(), 50, math.huge }, { sampled_ratios(), 3, 2 } }) do
      for _, recirc in ipairs({ true, false }) do
        for _, r in ipairs(entry[1]) do
          local n, m = r[1], r[2]
          local plain = build(n, m, { recirc = recirc })
          local lnet = build(n, m, { balance_lanes = true, recirc = recirc })
          assert(plain.lane_splitters == nil, "no lane splitters without opts")
          assert(#lnet.lane_splitters == n, string.format("%d:%d has %d lane splitters", n, m, #lnet.lane_splitters))
          for _, ed in ipairs(lnet.edges) do
            if ed.to.kind == "lane_splitter" then
              assert(ed.from.kind == "in", "lane splitter right after an input")
            end
          end
          check_outputs_equal(lnet)
          check_inputs_equal(lnet, 0.5)
          check_lanes(lnet, rand, entry[2], entry[3], not recirc)
        end
      end
    end
  end,

  -- Without balance_lanes the network keeps lanes: one lane in, the same lane out.
  network_keeps_lanes = function()
    for_each_mode(exhaustive_ratios(), function(net, n, m)
      local lanes = flow.solve_lanes(net, filled(n, 0.5), filled(n, 0), 1)
      for j = 1, m do
        local o = assert(lanes.out[j], "missing output")
        assert(near(o.right, 0), string.format("%d:%d output %d right lane not empty", n, m, j))
        assert(near(o.left, math.min(n, m) / (2 * m)), string.format("%d:%d output %d left lane", n, m, j))
      end
    end)
  end,

  loops_full_start_gives_the_same_flows = function()
    for_each_mode(exhaustive_ratios(), check_loops_full_start)
    for_each_mode(sampled_ratios(), check_loops_full_start)
  end,

  loops_drain_after_backpressure = function()
    for _, r in ipairs({ { 3, 5 }, { 5, 3 }, { 2, 3 }, { 9, 1 }, { 1, 40 } }) do
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
      local after = flow.shares(net, blocked)
      assert_values(after, filled(r[2], math.min(r[1], r[2]) / r[2]), tag(net) .. " after release")
    end
  end,

  recirc_one_slow_output = function()
    local rand = lcg(31)
    for_each(exhaustive_ratios(), function(net)
      check_one_slow_output(net, rand, 4)
    end)
    for_each(sampled_ratios(), function(net)
      check_one_slow_output(net, rand, 2)
    end)
  end,

  recirc_any_subset_of_slow_outputs = function()
    local rand = lcg(32)
    for_each(exhaustive_ratios(), function(net)
      check_slow_subsets(net, rand, 12)
    end)
    for_each(sampled_ratios(), function(net)
      check_slow_subsets(net, rand, 3)
    end)
  end,

  recirc_inputs_drawn_equally = function()
    local rand = lcg(33)
    for_each(exhaustive_ratios(), function(net)
      check_draw_under_backpressure(net, rand, 12)
    end)
    for_each(sampled_ratios(), function(net)
      check_draw_under_backpressure(net, rand, 3)
    end)
  end,

  -- The F8 case that broke the prototype: 3:5 with outputs 1 and 2 open draws equally.
  recirc_f8_case_draws_equally = function()
    local state = flow.solve(build(3, 5), { 1, 1, 1 }, { 1, 1, 0, 0, 0 })
    assert_values(inputs_of(state, 3), filled(3, 2 / 3), "3:5 with two outputs open")
  end,

  structure_is_well_formed = function()
    for _, ratios in ipairs({ exhaustive_ratios(), sampled_ratios() }) do
      for _, r in ipairs(ratios) do
        check_structure(build(r[1], r[2]))
        check_structure(build(r[1], r[2], { balance_lanes = true }))
        check_structure(build(r[1], r[2], { recirc = false }))
      end
    end
  end,

  degenerate_ratios_build = function()
    local one = build(1, 1)
    assert(#one.splitters == 0 and #one.priority == 0 and #one.edges == 1, "1:1 is a single edge")
    assert(#build(2, 1).splitters == 1 and #build(2, 1).priority == 0, "2:1 is one splitter")
    local rand = lcg(5)
    for _, r in ipairs({ { 1, 1 }, { 1, 8 }, { 8, 1 } }) do
      local net = build(r[1], r[2])
      check_outputs_equal(net)
      check_inputs_equal(net, 0.5)
      check_draw_under_backpressure(net, rand, 4)
      each_subset_pair(r[1], r[2], function(ins, outs)
        check_throughput(net, ins, outs)
        check_model_throughput(net, ins, outs)
      end, 8, 0)
    end
  end,

  -- Recirculation off: the Plan 1 network (no priority splitters), still exact.
  recirc_off_is_the_plain_network = function()
    for n = 1, 6 do
      for m = 1, 6 do
        local net = build(n, m, { recirc = false })
        assert(m == 1 or #net.priority == 0, string.format("%d:%d plain has priority splitters", n, m))
        check_outputs_equal(net)
        check_inputs_equal(net, 0.5)
        each_subset_pair(n, m, function(ins, outs)
          check_throughput(net, ins, outs)
          check_model_throughput(net, ins, outs)
        end, 4, 25)
      end
    end
  end,

  invalid_sizes_are_refused = function()
    for _, r in ipairs({ { 0, 2 }, { 2, 0 }, { 1.5, 2 }, { "3", 2 } }) do
      ---@diagnostic disable-next-line: param-type-mismatch
      local net, err = network.build(r[1], r[2])
      assert(net == nil and err == "invalid", tostring(r[1]) .. ":" .. tostring(r[2]) .. " must be refused")
    end
    assert(rawget(network, "MAX_SIDE") == nil, "MAX_SIDE is removed")
  end,

  no_size_cap = function()
    local rand = lcg(200)
    for _, r in ipairs({ { 200, 7 }, { 7, 200 } }) do
      local n, m = r[1], r[2]
      -- Best of three, so a garbage collection cycle does not count. This is the suite's only
      -- wall-clock assertion. Measured best of five on an idle machine: 200:7 16 ms, 7:200 41 ms,
      -- so the old 50 ms bound failed whenever the machine was busy (the flaky run of the Task 2
      -- review). The bound is now loose: it catches a blow-up, not a slowdown.
      local best = math.huge
      local net
      for _ = 1, 3 do
        local t = os.clock()
        net = build(n, m)
        best = math.min(best, os.clock() - t)
      end
      assert(best < 1.0, string.format("%d:%d builds in %.1f ms", n, m, best * 1000))
      check_structure(net)
      check_any_input_mix(net, rand, 20, 0)
      check_one_slow_output(net, rand, 2)
      check_slow_subsets(net, rand, 2)
      check_draw_under_backpressure(net, rand, 2)
      each_subset_pair(n, m, function(ins, outs)
        check_model_throughput(net, ins, outs)
      end, 0, 2, rand)
    end
  end,

  build_is_deterministic = function()
    local a, b = build(5, 3), build(5, 3)
    assert(#a.edges == #b.edges, "same edge count")
    for e = 1, #a.edges do
      local x, y = a.edges[e], b.edges[e]
      for _, k in ipairs({ "from", "to" }) do
        assert(x[k].kind == y[k].kind and x[k].id == y[k].id and x[k].port == y[k].port, "same edges")
      end
    end
  end,

  -- Two butterflies are a Benes network: (2k - 1) * 2^(k - 1) splitters for a plain 2^k:2^k.
  benes_core_sizes = function()
    for k, want in pairs({ [2] = 6, [3] = 20, [4] = 56, [6] = 352, [7] = 832 }) do
      local net = build(2 ^ k, 2 ^ k, { recirc = false })
      assert(#net.splitters == want, string.format("%d:%d plain has %d splitters, expected %d", 2 ^ k, 2 ^ k, #net.splitters, want))
    end
  end,

  -- fold(): no plain splitter sends both its outputs into the same node.
  no_redundant_splitter_pairs = function()
    for _, ratios in ipairs({ exhaustive_ratios(), sampled_ratios() }) do
      for _, r in ipairs(ratios) do
        for _, opts in ipairs({ {}, { recirc = false }, { balance_lanes = true } }) do
          local net = build(r[1], r[2], opts)
          local target = {}
          for _, ed in ipairs(net.edges) do
            if ed.from.kind == "splitter" then
              local key = ed.to.kind .. ":" .. ed.to.id
              local prev = target[ed.from.id]
              assert(not (prev and prev == key and ed.to.kind ~= "out"),
                string.format("%s: splitter %d feeds both inputs of %s", tag(net), ed.from.id, key))
              target[ed.from.id] = key
            end
          end
        end
      end
    end
  end,

  size_table = function()
    local parts = {}
    for _, r in ipairs({ { 1, 2 }, { 2, 2 }, { 5, 2 }, { 2, 3 }, { 3, 5 }, { 8, 3 }, { 9, 1 }, { 17, 2 }, { 33, 5 }, { 16, 16 }, { 64, 64 } }) do
      local s = build(r[1], r[2]).stats
      parts[#parts + 1] = string.format(
        "%d:%d=%d+%dp/%de",
        r[1],
        r[2],
        s.splitters,
        s.priority,
        s.edges
      )
    end
    print("  sizes (splitters+priority/edges): " .. table.concat(parts, " "))
  end,
}
