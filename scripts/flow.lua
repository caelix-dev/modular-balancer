-- Steady-state flow model of a splitter network (scripts/network.lua format). Pure Lua,
-- no game API, deterministic.
--
-- Model (vanilla splitters, plus splitters with output priority):
-- - Flow is measured in belts: every edge carries at most 1.0.
-- - A splitter moves T = min(supply in, demand out) and splits T equally between its
--   outputs, except that an output that cannot take its half (blocked) gets what it can
--   take and the other output gets the rest (water filling). It draws from its inputs the
--   same way: equally, except that an input that cannot supply its half (starved) gives
--   what it has and the other input gives the rest.
-- - An unconnected splitter input supplies nothing. An unconnected splitter output takes
--   nothing (in the game it is a dead end that fills with a few items and then blocks).
-- - A lane splitter passes belt totals through unchanged. flow.solve_lanes models lanes.
-- - A priority splitter (kind "priority", splitter_output_priority on output port 1) sends
--   what port 1 can take to port 1 and only the rest to port 2. It draws its inputs like
--   a plain splitter (no input priority):
--     s(out 1) = min(a1 + a2, 1)
--     s(out 2) = min(max(0, a1 + a2 - b1), 1)
--   This rule reproduces the F8 engine measurements of the recirculation prototype (3:5
--   with two outputs open drew 45 / 22.5 / 22.5 items/s; 2:3 with a slow output gave
--   15 / 37.5 / 37.5), pinned by flow_test.lua::f8_prototype_matches_the_engine.
--
-- Every edge e has a supply s[e] (what its upstream node could push into it if the edge
-- took everything) and a demand d[e] (what its downstream node could take from it if the
-- edge supplied everything); its flow is f[e] = min(s[e], d[e]). For a splitter with
-- input supplies a1, a2 and output demands b1, b2:
--   s(out j) = max(T/2, T - b_other)  with T = min(a1 + a2, 1 + b_other)
--   d(in i)  = max(T/2, T - a_other)  with T = min(1 + a_other, b1 + b2)
-- At a fixed point these flows conserve items at every splitter and reproduce the
-- water-filling split above (see the conservation checks in tests/unit/flow_test.lua).
--
-- Offline only: tests/unit uses this module to prove the generator's networks; the mod
-- does not load it at runtime (Plan 2 runs only scripts/network.lua in game). If it is ever
-- used in game, call it only from build events and handle its error.
--
-- Loops are solved by Gauss-Seidel fixed-point iteration (sweeps alternate between the
-- node order and its reverse), sweeping all nodes until the
-- largest change in one sweep is at most TOLERANCE (1e-13, below the 1e-12 the plan asks
-- for). That is a step size, not a residual: with geometric convergence at rate r the
-- remaining error is about TOLERANCE * r / (1 - r), so 1e-13 keeps it far below the tests'
-- 1e-9 for any rate seen (at most about 1 700 sweeps over all 256 ratios). The update is
-- monotone (supply up, demand down), so from the default start (no inner supply, full
-- demand) it converges to the least fixed point and from the loops-full start (supply 1,
-- demand 0) to the greatest; their network input and output flows agree (tested). It
-- raises an error after MAX_SWEEPS sweeps.
--
-- Where this can differ from the engine (Task 5 measures the engine):
-- - Steady state only: no transients, belt lengths, item spacing or discrete items. A
--   real splitter alternates item by item per lane; the model uses the long-run average.
-- - The model assumes every edge reaches the full belt rate 1.0 when supplied and not
--   blocked. A linked-belt pair or a splitter that loses compression would cap below 1.0.
-- - flow.solve treats the belt as one stream. flow.solve_lanes splits it into two lanes of
--   0.5 each, assuming a splitter splits each lane independently (F3) and a lane splitter
--   water-fills between lanes like a splitter between belts (F5 measured only 1:2).
-- - If a network had several steady states the model returns the one reached from the
--   initial values (default: no supply on inner edges, full demand). The tests also start
--   from the all-blocked state.
-- - max_throughput is a graph max flow (what some routing can achieve), not a simulation.
--   network_test.lua additionally checks that the splitter model reaches it.
local flow = {}

flow.TOLERANCE = 1e-13
flow.MAX_SWEEPS = 100000

local function index(net)
  local idx = {
    in_edge = {},
    out_edge = {},
    nodes = {}, -- { kind, ins = {e1, e2}, outs = {e1, e2} } (missing port = nil)
  }
  local by_key = {}
  local function node(kind, id)
    local key = kind .. ":" .. id
    local n = by_key[key]
    if not n then
      n = { kind = kind, ins = {}, outs = {} }
      by_key[key] = n
      idx.nodes[#idx.nodes + 1] = n
    end
    return n
  end
  for _, s in ipairs(net.splitters) do
    node("splitter", s.id)
  end
  for _, p in ipairs(net.priority or {}) do
    node("priority", p.id)
  end
  for _, l in ipairs(net.lane_splitters or {}) do
    node("lane_splitter", l.id)
  end
  for e, ed in ipairs(net.edges) do
    local from, to = ed.from, ed.to
    if from.kind == "in" then
      idx.in_edge[from.id] = e
    else
      node(from.kind, from.id).outs[from.port or 1] = e
    end
    if to.kind == "out" then
      idx.out_edge[to.id] = e
    else
      node(to.kind, to.id).ins[to.port or 1] = e
    end
  end
  return idx
end

-- supply[i]: what input i offers (0..1). demand[j]: what output j takes (0..1).
-- init: an earlier state of the same network to start from.
-- Returns { s = {}, d = {}, f = {}, sweeps = n }, indexed by edge.
-- Also accepts flow.solve(net, { supply = , demand = , init = }).
function flow.solve(net, supply, demand, init)
  if demand == nil and type(supply) == "table" and supply.supply then
    supply, demand, init = supply.supply, supply.demand, supply.init
  end
  local idx = index(net)
  ---@type number[]
  local s = {}
  ---@type number[]
  local d = {}
  for e = 1, #net.edges do
    s[e] = init and init.s[e] or 0
    d[e] = init and init.d[e] or 1
  end
  for i, e in pairs(idx.in_edge) do
    s[e] = math.min(1, supply[i] or 0)
  end
  for j, e in pairs(idx.out_edge) do
    d[e] = math.min(1, demand[j] or 0)
  end

  -- Flat per-node arrays for the inner loop: kind code (1 splitter, 2 priority, 3 lane
  -- splitter) and the edge on each port (false when unconnected).
  local nodes = idx.nodes
  local count = #nodes
  local K, I1, I2, O1, O2 = {}, {}, {}, {}, {}
  for ni, n in ipairs(nodes) do
    K[ni] = n.kind == "splitter" and 1 or n.kind == "priority" and 2 or 3
    I1[ni], I2[ni], O1[ni], O2[ni] = n.ins[1] or false, n.ins[2] or false, n.outs[1] or false, n.outs[2] or false
  end
  local min, abs = math.min, math.abs

  local sweeps = 0
  while true do
    sweeps = sweeps + 1
    if sweeps > flow.MAX_SWEEPS then
      error("flow.solve: no convergence after " .. flow.MAX_SWEEPS .. " sweeps")
    end
    ---@type number
    local change = 0
    -- Alternate the sweep direction: supply travels forward and demand backward through
    -- the node order, so each reaches across the network in one sweep.
    local first, last, step = 1, count, 1
    if sweeps % 2 == 0 then
      first, last, step = count, 1, -1
    end
    for ni = first, last, step do
      local i1, i2, o1, o2 = I1[ni], I2[ni], O1[ni], O2[ni]
      local a1, a2 = i1 and s[i1] or 0, i2 and s[i2] or 0
      local b1, b2 = o1 and d[o1] or 0, o2 and d[o2] or 0
      local v1, v2, w1, w2 -- new s on outputs 1, 2 and new d on inputs 1, 2
      local kind = K[ni]
      if kind == 3 then
        v1, w1 = a1, b1
      else
        if kind == 2 then
          local a = a1 + a2
          v1 = min(a, 1)
          v2 = a - b1
          v2 = v2 < 0 and 0 or (v2 > 1 and 1 or v2)
        else
          local T, r
          T = min(a1 + a2, 1 + b2)
          r = T - b2
          v1 = r > T / 2 and r or T / 2
          T = min(a1 + a2, 1 + b1)
          r = T - b1
          v2 = r > T / 2 and r or T / 2
        end
        local T, r
        T = min(1 + a2, b1 + b2)
        r = T - a2
        w1 = r > T / 2 and r or T / 2
        T = min(1 + a1, b1 + b2)
        r = T - a1
        w2 = r > T / 2 and r or T / 2
      end
      if o1 then
        local delta = abs(s[o1] - v1)
        if delta > change then
          change = delta
        end
        s[o1] = v1
      end
      if o2 and v2 then
        local delta = abs(s[o2] - v2)
        if delta > change then
          change = delta
        end
        s[o2] = v2
      end
      if i1 then
        local delta = abs(d[i1] - w1)
        if delta > change then
          change = delta
        end
        d[i1] = w1
      end
      if i2 and w2 then
        local delta = abs(d[i2] - w2)
        if delta > change then
          change = delta
        end
        d[i2] = w2
      end
    end
    if change <= flow.TOLERANCE then
      break
    end
  end

  local f = {}
  for e = 1, #net.edges do
    f[e] = math.min(s[e] --[[@as number]], d[e] --[[@as number]])
  end
  return { s = s, d = d, f = f, sweeps = sweeps, in_edge = idx.in_edge, out_edge = idx.out_edge }
end

local function constant(n, v)
  local t = {}
  for i = 1, n do
    t[i] = v
  end
  return t
end

-- All inputs fed at 1.0, outputs unbounded. Returns shares by output index, and the state.
function flow.shares(net, init)
  local state = flow.solve(net, constant(net.n_in, 1), constant(net.n_out, 1), init)
  local out = {}
  for j = 1, net.n_out do
    out[j] = state.f[state.out_edge[j]]
  end
  return out, state
end

-- All inputs saturated, every output limited to out_capacity. Returns the draw by input
-- index, and the state.
function flow.input_draw(net, out_capacity, init)
  local state = flow.solve(net, constant(net.n_in, 1), constant(net.n_out, out_capacity), init)
  local draw = {}
  for i = 1, net.n_in do
    draw[i] = state.f[state.in_edge[i]]
  end
  return draw, state
end

-- Lane-aware variant. Every belt edge becomes two lane edges of 0.5 belt each. A splitter
-- keeps lanes, so it becomes two independent splitters, one per lane. A lane splitter
-- becomes a splitter between the two lanes (equal split and equal draw, as above). The
-- lane network is solved by flow.solve in half-belt units (capacity 1 per lane).
-- left[i], right[i]: supply of input i's lanes in belts (0..0.5). out_capacity: what each
-- output takes in belts, half per lane (a number, or a table by output index). A priority
-- splitter becomes two per-lane priority splitters. Returns
-- { out = { [j] = {left, right} }, draw = { [i] = belts }, state } in belts.
---@return { out: { left: number, right: number }[], draw: number[], state: table }
function flow.solve_lanes(net, left, right, out_capacity)
  local n_splitters = 0
  for _, s in ipairs(net.splitters) do
    n_splitters = math.max(n_splitters, s.id)
  end
  local function lane_port(p, lane)
    if p.kind == "in" or p.kind == "out" then
      return { kind = p.kind, id = 2 * p.id - 2 + lane, port = 1 }
    elseif p.kind == "splitter" or p.kind == "priority" then
      return { kind = p.kind, id = 2 * p.id - 2 + lane, port = p.port }
    end
    -- Lane splitter: lane 1 on port 1, lane 2 on port 2.
    return { kind = "splitter", id = 2 * n_splitters + p.id, port = lane }
  end
  local lnet = { n_in = 2 * net.n_in, n_out = 2 * net.n_out, splitters = {}, priority = {}, edges = {} }
  for _, p in ipairs(net.priority or {}) do
    lnet.priority[#lnet.priority + 1] = { kind = "priority", id = 2 * p.id - 1 }
    lnet.priority[#lnet.priority + 1] = { kind = "priority", id = 2 * p.id }
  end
  for _, s in ipairs(net.splitters) do
    lnet.splitters[#lnet.splitters + 1] = { id = 2 * s.id - 1 }
    lnet.splitters[#lnet.splitters + 1] = { id = 2 * s.id }
  end
  for _, l in ipairs(net.lane_splitters or {}) do
    lnet.splitters[#lnet.splitters + 1] = { id = 2 * n_splitters + l.id }
  end
  for _, ed in ipairs(net.edges) do
    for lane = 1, 2 do
      lnet.edges[#lnet.edges + 1] = { from = lane_port(ed.from, lane), to = lane_port(ed.to, lane) }
    end
  end

  local supply, demand = {}, {}
  for i = 1, net.n_in do
    supply[2 * i - 1], supply[2 * i] = 2 * (left[i] or 0), 2 * (right[i] or 0)
  end
  for j = 1, net.n_out do
    local cap = type(out_capacity) == "table" and out_capacity[j] or out_capacity
    demand[2 * j - 1], demand[2 * j] = cap, cap
  end
  local state = flow.solve(lnet, supply, demand)
  local result = { out = {}, draw = {}, state = state }
  for j = 1, net.n_out do
    result.out[j] = {
      left = state.f[state.out_edge[2 * j - 1]] / 2,
      right = state.f[state.out_edge[2 * j]] / 2,
    }
  end
  for i = 1, net.n_in do
    result.draw[i] = (state.f[state.in_edge[2 * i - 1]] + state.f[state.in_edge[2 * i]]) / 2
  end
  return result
end

-- Max flow (Edmonds-Karp) from the inputs `ins` to the outputs `outs` (index lists).
-- Every edge has capacity 1.0; a splitter therefore passes at most 2.0 and a lane splitter
-- 1.0, so node capacities need no extra arcs.
function flow.max_throughput(net, ins, outs)
  local use_in, use_out = {}, {}
  for _, i in ipairs(ins) do
    use_in[i] = true
  end
  for _, j in ipairs(outs) do
    use_out[j] = true
  end

  local ids, count = {}, 0
  local function vertex(key)
    local v = ids[key]
    if not v then
      count = count + 1
      v = count
      ids[key] = v
    end
    return v
  end
  local source, sink = vertex("source"), vertex("sink")
  local head, to, cap, rev = {}, {}, {}, {} -- adjacency lists of arc ids; rev = paired arc
  local arcs = 0
  local function half(u, v, c)
    arcs = arcs + 1
    to[arcs], cap[arcs] = v, c
    head[u] = head[u] or {}
    table.insert(head[u], arcs)
    return arcs
  end
  local function arc(u, v, c)
    local a = half(u, v, c)
    local b = half(v, u, 0)
    rev[a], rev[b] = b, a
  end

  for _, ed in ipairs(net.edges) do
    local from, dst = ed.from, ed.to
    local u, v
    if from.kind == "in" then
      u = use_in[from.id] and source or nil
    else
      u = vertex(from.kind .. ":" .. from.id)
    end
    if dst.kind == "out" then
      v = use_out[dst.id] and sink or nil
    else
      v = vertex(dst.kind .. ":" .. dst.id)
    end
    if u and v then
      arc(u, v, 1)
    end
  end

  ---@type number
  local total = 0
  while true do
    local prev = { [source] = -1 }
    local queue, qi = { source }, 1
    while qi <= #queue and prev[sink] == nil do
      local u = queue[qi]
      qi = qi + 1
      for _, a in ipairs(head[u] or {}) do
        local v = to[a]
        if cap[a] > 1e-12 and prev[v] == nil then
          prev[v] = a
          queue[#queue + 1] = v
        end
      end
    end
    if prev[sink] == nil then
      break
    end
    local push = math.huge
    local v = sink
    while v ~= source do
      local a = prev[v]
      push = math.min(push, cap[a])
      v = to[rev[a]]
    end
    v = sink
    while v ~= source do
      local a = prev[v]
      cap[a] = cap[a] - push
      cap[rev[a]] = cap[rev[a]] + push
      v = to[rev[a]]
    end
    total = total + push
  end
  return total
end

return flow
