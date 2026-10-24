local flow = require("scripts.flow")

local EPS = 1e-9

local function near(a, b)
  return math.abs(a - b) <= EPS
end

local function port(kind, id, p)
  return { kind = kind, id = id, port = p or 1 }
end

local function edge(from, to)
  return { from = from, to = to }
end

-- One splitter fed on input port 1 (input port 2 unconnected), two outputs.
local function one_splitter_1_2()
  return {
    n_in = 1,
    n_out = 2,
    splitters = { { id = 1 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("splitter", 1, 1), port("out", 1)),
      edge(port("splitter", 1, 2), port("out", 2)),
    },
  }
end

-- Two stages: splitter 1 feeds splitters 2 and 3, which feed the four outputs.
local function chain_1_4()
  return {
    n_in = 1,
    n_out = 4,
    splitters = { { id = 1 }, { id = 2 }, { id = 3 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("splitter", 1, 1), port("splitter", 2, 1)),
      edge(port("splitter", 1, 2), port("splitter", 3, 1)),
      edge(port("splitter", 2, 1), port("out", 1)),
      edge(port("splitter", 2, 2), port("out", 2)),
      edge(port("splitter", 3, 1), port("out", 3)),
      edge(port("splitter", 3, 2), port("out", 4)),
    },
  }
end

local function one_splitter_2_2()
  return {
    n_in = 2,
    n_out = 2,
    splitters = { { id = 1 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("in", 2), port("splitter", 1, 2)),
      edge(port("splitter", 1, 1), port("out", 1)),
      edge(port("splitter", 1, 2), port("out", 2)),
    },
  }
end

-- 1:1 through a splitter whose second output loops back into its second input.
local function looped_1_1()
  return {
    n_in = 1,
    n_out = 1,
    splitters = { { id = 1 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("splitter", 1, 1), port("out", 1)),
      edge(port("splitter", 1, 2), port("splitter", 1, 2)),
    },
  }
end

-- 1:3 exact: splitter 1 -> splitters 2 and 3; three outputs, the fourth loops back
-- into splitter 1's second input.
local function looped_1_3()
  return {
    n_in = 1,
    n_out = 3,
    splitters = { { id = 1 }, { id = 2 }, { id = 3 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("splitter", 3, 2), port("splitter", 1, 2)),
      edge(port("splitter", 1, 1), port("splitter", 2, 1)),
      edge(port("splitter", 1, 2), port("splitter", 3, 1)),
      edge(port("splitter", 2, 1), port("out", 1)),
      edge(port("splitter", 2, 2), port("out", 2)),
      edge(port("splitter", 3, 1), port("out", 3)),
    },
  }
end

-- Two inputs merged by a splitter whose second output is unconnected (blocked).
local function merge_2_1()
  return {
    n_in = 2,
    n_out = 1,
    splitters = { { id = 1 } },
    edges = {
      edge(port("in", 1), port("splitter", 1, 1)),
      edge(port("in", 2), port("splitter", 1, 2)),
      edge(port("splitter", 1, 1), port("out", 1)),
    },
  }
end

local function assert_all(values, expected, what)
  for i, v in pairs(values) do
    assert(near(v, expected), string.format("%s[%d] = %.15g, expected %.15g", what, i, v, expected))
  end
end

local function assert_conserved(net, state)
  -- Sum of flow into and out of every splitter must match.
  local net_in, net_out = {}, {}
  for e, ed in ipairs(net.edges) do
    local f = state.f[e]
    if ed.to.kind == "splitter" then
      net_in[ed.to.id] = (net_in[ed.to.id] or 0) + f
    end
    if ed.from.kind == "splitter" then
      net_out[ed.from.id] = (net_out[ed.from.id] or 0) + f
    end
  end
  for _, s in ipairs(net.splitters) do
    local a, b = net_in[s.id] or 0, net_out[s.id] or 0
    assert(near(a, b), string.format("splitter %d: in %.15g, out %.15g", s.id, a, b))
  end
end

return {
  one_splitter_splits_in_half = function()
    local shares = flow.shares(one_splitter_1_2())
    assert(#shares == 2, "two outputs")
    assert_all(shares, 0.5, "shares")
  end,

  two_stage_chain_splits_in_quarters = function()
    local shares = flow.shares(chain_1_4())
    assert(#shares == 4, "four outputs")
    assert_all(shares, 0.25, "shares")
  end,

  max_throughput_of_one_splitter_is_two = function()
    local t = flow.max_throughput(one_splitter_2_2(), { 1, 2 }, { 1, 2 })
    assert(near(t, 2), "max throughput " .. t)
    assert(near(flow.max_throughput(one_splitter_2_2(), { 1 }, { 2 }), 1), "one to one")
  end,

  max_throughput_respects_the_edge_capacity = function()
    -- Both inputs into one output: limited by the single output edge.
    assert(near(flow.max_throughput(merge_2_1(), { 1, 2 }, { 1 }), 1), "merge is 1")
  end,

  loop_back_into_itself_passes_everything = function()
    local shares, state = flow.shares(looped_1_1())
    assert_all(shares, 1, "shares")
    assert_conserved(looped_1_1(), state)
  end,

  loop_gives_exact_thirds = function()
    local net = looped_1_3()
    local shares, state = flow.shares(net)
    assert_all(shares, 1 / 3, "shares")
    assert_conserved(net, state)
  end,

  blocked_outputs_stop_everything = function()
    local net = looped_1_3()
    local draw, state = flow.input_draw(net, 0)
    assert(near(draw[1], 0), "draw " .. draw[1])
    for e = 1, #net.edges do
      assert(near(state.f[e], 0), "edge " .. e .. " still flows: " .. state.f[e])
    end
    local shares = flow.shares(net, state)
    assert_all(shares, 1 / 3, "shares after release")
  end,

  merge_draws_inputs_equally = function()
    local draw, state = flow.input_draw(merge_2_1(), 0.5)
    assert_all(draw, 0.25, "draw")
    assert_conserved(merge_2_1(), state)
  end,

  backpressure_moves_flow_to_the_free_output = function()
    -- Splitter 2:2 with output 1 limited to 0.25: output 2 takes 0.75 (capped at 1).
    local net = one_splitter_2_2()
    local state = flow.solve(net, { 1, 1 }, { 0.25, 1 })
    assert(near(state.f[3], 0.25), "out 1 " .. state.f[3])
    assert(near(state.f[4], 1), "out 2 " .. state.f[4])
    assert(near(state.f[1], 0.625) and near(state.f[2], 0.625), "inputs drawn equally")
  end,

  starved_input_lets_the_other_supply_more = function()
    -- Input 1 supplies 0.2, outputs demand 0.5 each: input 2 supplies 0.8.
    local net = one_splitter_2_2()
    local state = flow.solve(net, { 0.2, 1 }, { 0.5, 0.5 })
    assert(near(state.f[1], 0.2) and near(state.f[2], 0.8), "draws " .. state.f[1] .. " " .. state.f[2])
    assert(near(state.f[3], 0.5) and near(state.f[4], 0.5), "outputs")
  end,

  lane_splitter_is_a_pass_through = function()
    local net = one_splitter_1_2()
    net.lane_splitters = { { kind = "lane_splitter", id = 1 } }
    net.edges[1] = edge(port("in", 1), port("lane_splitter", 1))
    table.insert(net.edges, edge(port("lane_splitter", 1), port("splitter", 1, 1)))
    local shares = flow.shares(net)
    assert_all(shares, 0.5, "shares")
    assert(near(flow.max_throughput(net, { 1 }, { 1, 2 }), 1), "max throughput through lane splitter")
  end,
  lane_model_keeps_lanes_through_a_splitter = function()
    -- Only the left lane fed: a splitter keeps lanes, so each output gets 0.25 on its left.
    local lanes = flow.solve_lanes(one_splitter_1_2(), { 0.5 }, { 0 }, 1)
    for j = 1, 2 do
      local o = assert(lanes.out[j], "missing output")
      assert(near(o.left, 0.25) and near(o.right, 0), "output " .. j)
    end
  end,

  lane_model_caps_each_lane_at_half_a_belt = function()
    -- Merge 2:1 with only left lanes fed: the output's left lane caps the total at 0.5.
    local lanes = flow.solve_lanes(merge_2_1(), { 0.5, 0.5 }, { 0, 0 }, 1)
    local o = assert(lanes.out[1], "missing output")
    assert(near(o.left, 0.5) and near(o.right, 0), "left lane full, right empty")
    assert(near(lanes.draw[1], 0.25) and near(lanes.draw[2], 0.25), "drawn equally")
  end,

  lane_splitter_balances_lanes = function()
    local net = one_splitter_1_2()
    net.lane_splitters = { { kind = "lane_splitter", id = 1 } }
    net.edges[1] = edge(port("in", 1), port("lane_splitter", 1))
    table.insert(net.edges, edge(port("lane_splitter", 1), port("splitter", 1, 1)))
    local lanes = flow.solve_lanes(net, { 0.5 }, { 0 }, 1)
    for j = 1, 2 do
      local o = assert(lanes.out[j], "missing output")
      assert(near(o.left, 0.125) and near(o.right, 0.125), "output " .. j)
    end
  end,
}
