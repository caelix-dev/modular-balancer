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

-- One priority splitter fed on input 1: port 1 to output 1, port 2 to output 2.
local function one_priority()
  return {
    n_in = 1,
    n_out = 2,
    splitters = {},
    priority = { { kind = "priority", id = 1 } },
    edges = {
      edge(port("in", 1), port("priority", 1, 1)),
      edge(port("priority", 1, 1), port("out", 1)),
      edge(port("priority", 1, 2), port("out", 2)),
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
  priority_port_one_takes_what_it_can = function()
    local state = flow.solve(one_priority(), { 1 }, { 0.3, 1 })
    assert(near(state.f[2], 0.3) and near(state.f[3], 0.7), "0.3 / 0.7: " .. state.f[2] .. " / " .. state.f[3])
    state = flow.solve(one_priority(), { 1 }, { 1, 1 })
    assert(near(state.f[2], 1) and near(state.f[3], 0), "1.0 / 0")
  end,

  priority_overflow_blocked_backs_up = function()
    -- Port 1 takes 0.3 and port 2 is blocked: the input is drawn at 0.3.
    local state = flow.solve(one_priority(), { 1 }, { 0.3, 0 })
    assert(near(state.f[1], 0.3) and near(state.f[2], 0.3) and near(state.f[3], 0), "backs up to 0.3")
  end,

  priority_draws_its_inputs_equally = function()
    local net = one_priority()
    net.n_in = 2
    table.insert(net.edges, edge(port("in", 2), port("priority", 1, 2)))
    local state = flow.solve(net, { 1, 1 }, { 0.5, 0.3 })
    assert(near(state.f[1], 0.4) and near(state.f[4], 0.4), "inputs 0.4 each")
    assert(near(state.f[2], 0.5) and near(state.f[3], 0.3), "0.5 / 0.3")
  end,

  priority_recirculation_loop_is_exact = function()
    -- 1:2 splitter whose outputs pass priority splitters; overflow returns to the splitter's
    -- second input. Output 1 takes 0.2: output 2 gets the remaining 0.8.
    local net = {
      n_in = 1,
      n_out = 2,
      splitters = { { id = 1 } },
      priority = { { kind = "priority", id = 1 }, { kind = "priority", id = 2 } },
      edges = {
        edge(port("in", 1), port("splitter", 1, 1)),
        edge(port("splitter", 1, 1), port("priority", 1, 1)),
        edge(port("splitter", 1, 2), port("priority", 2, 1)),
        edge(port("priority", 1, 1), port("out", 1)),
        edge(port("priority", 2, 1), port("out", 2)),
        edge(port("priority", 1, 2), port("priority", 2, 2)),
        edge(port("priority", 2, 2), port("splitter", 1, 2)),
      },
    }
    local state = flow.solve(net, { 1 }, { 0.2, 1 })
    assert(near(state.f[4], 0.2) and near(state.f[5], 0.8), "0.2 / 0.8: " .. state.f[4] .. " / " .. state.f[5])
    assert(near(flow.max_throughput(net, { 1 }, { 2 }), 1), "max flow through priority")
    local lanes = flow.solve_lanes(net, { 0.5 }, { 0 }, { 0.2, 1 })
    local o1, o2 = assert(lanes.out[1], "out 1"), assert(lanes.out[2], "out 2")
    assert(near(o1.left, 0.1) and near(o2.left, 0.4), "lane-aware priority: " .. o1.left .. " / " .. o2.left)
  end,

  solve_accepts_an_options_table = function()
    local a = flow.solve(one_priority(), { 1 }, { 0.3, 1 })
    local b = flow.solve(one_priority(), { supply = { 1 }, demand = { 0.3, 1 } })
    for e = 1, 3 do
      assert(near(a.f[e], b.f[e]), "same flows")
    end
  end,
  -- Engine agreement (docs/feasibility.md F8, measured in game): the F8 prototype, a plain
  -- (n + M):M network whose output j passes a priority splitter with port 2 fed back into
  -- input n + j. 3:5 with outputs 1 and 2 open drew 45 / 22.5 / 22.5 items/s (1 / 0.5 / 0.5
  -- belts); 2:3 with output 1 slow (15 of 45) gave 15 / 37.5 / 37.5.
  f8_prototype_matches_the_engine = function()
    local network = require("scripts.network")
    ---@param n integer
    ---@param m integer
    local function f8(n, m)
      local plain = assert(network.build(n + m, m, { recirc = false }))
      local net = { n_in = n, n_out = m, splitters = plain.splitters, priority = {}, edges = {} }
      for j = 1, m do
        net.priority[j] = { kind = "priority", id = j }
        table.insert(net.edges, edge(port("priority", j, 1), port("out", j)))
      end
      for _, ed in ipairs(plain.edges) do
        local from, to = ed.from, ed.to
        if from.kind == "in" and from.id > n then
          from = port("priority", from.id - n, 2)
        end
        if to.kind == "out" then
          to = port("priority", to.id, 1)
        end
        table.insert(net.edges, edge(from, to))
      end
      return net
    end
    local function full(net)
      local init = { s = {}, d = {} }
      for e = 1, #net.edges do
        init.s[e], init.d[e] = 1, 0
      end
      return init
    end
    local net = f8(3, 5)
    for _, init in ipairs({ false, full(net) }) do
      local state = flow.solve(net, { 1, 1, 1 }, { 1, 1, 0, 0, 0 }, init or nil)
      local d = { state.f[state.in_edge[1]], state.f[state.in_edge[2]], state.f[state.in_edge[3]] }
      table.sort(d)
      assert(near(d[1], 0.5) and near(d[2], 0.5) and near(d[3], 1), "3:5 two open: " .. table.concat(d, " / "))
    end
    net = f8(2, 3)
    local state = flow.solve(net, { 1, 1 }, { 1 / 3, 1, 1 })
    local o = { state.f[state.out_edge[1]], state.f[state.out_edge[2]], state.f[state.out_edge[3]] }
    assert(near(o[1], 1 / 3) and near(o[2], 2.5 / 3) and near(o[3], 2.5 / 3), "2:3 slow: " .. table.concat(o, " / "))
  end,
}
