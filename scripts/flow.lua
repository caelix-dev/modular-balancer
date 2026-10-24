-- Steady-state flow model of a splitter network (scripts/network.lua format). Pure Lua,
-- no game API, deterministic.
--
-- Model (vanilla splitters, no priority):
-- - Flow is measured in belts: every edge carries at most 1.0.
-- - A splitter moves T = min(supply in, demand out) and splits T equally between its
--   outputs, except that an output that cannot take its half (blocked) gets what it can
--   take and the other output gets the rest (water filling). It draws from its inputs the
--   same way: equally, except that an input that cannot supply its half (starved) gives
--   what it has and the other input gives the rest.
-- - An unconnected splitter input supplies nothing. An unconnected splitter output takes
--   nothing (in the game it is a dead end that fills with a few items and then blocks).
-- - A lane splitter passes belt totals through unchanged (lanes are checked in game).
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
-- Loops are solved by Gauss-Seidel fixed-point iteration, sweeping all nodes until no
-- value changes by more than TOLERANCE (1e-13, below the 1e-12 the plan asks for). It
-- raises an error if it does not converge within MAX_SWEEPS.
--
-- Where this can differ from the engine (Task 5 measures the engine):
-- - Steady state only: no transients, belt lengths, item spacing or discrete items. A
--   real splitter alternates item by item per lane; the model uses the long-run average.
-- - The model assumes every edge reaches the full belt rate 1.0 when supplied and not
--   blocked. A linked-belt pair or a splitter that loses compression would cap below 1.0.
-- - Lanes are not modelled; the network treats the belt as one stream.
-- - If a network had several steady states the model returns the one reached from the
--   initial values (default: no supply on inner edges, full demand). The tests also start
--   from the all-blocked state.
-- - max_throughput is a graph max flow (what some routing can achieve), not a simulation.
--   network_test.lua additionally checks that the splitter model reaches it.
local flow = {}

flow.TOLERANCE = 1e-13
flow.MAX_SWEEPS = 1000000

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

local function waterfill_cap(total, other)
  local t = total / 2
  local rest = total - other
  if rest > t then
    return rest
  end
  return t
end

-- supply[i]: what input i offers (0..1). demand[j]: what output j takes (0..1).
-- init: an earlier state of the same network to start from.
-- Returns { s = {}, d = {}, f = {}, sweeps = n }, indexed by edge.
function flow.solve(net, supply, demand, init)
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

  local function set(tbl, e, v)
    local delta = math.abs(tbl[e] - v)
    tbl[e] = v
    return delta
  end

  local sweeps = 0
  while true do
    sweeps = sweeps + 1
    if sweeps > flow.MAX_SWEEPS then
      error("flow.solve: no convergence after " .. flow.MAX_SWEEPS .. " sweeps")
    end
    ---@type number
    local change = 0
    for _, n in ipairs(idx.nodes) do
      if n.kind == "lane_splitter" then
        local i, o = n.ins[1], n.outs[1]
        if o then
          change = math.max(change, set(s, o, (i and s[i] or 0) --[[@as number]]))
        end
        if i then
          change = math.max(change, set(d, i, (o and d[o] or 0) --[[@as number]]))
        end
      else
        local i1, i2, o1, o2 = n.ins[1], n.ins[2], n.outs[1], n.outs[2]
        local a1, a2 = i1 and s[i1] or 0, i2 and s[i2] or 0
        local b1, b2 = o1 and d[o1] or 0, o2 and d[o2] or 0
        if o1 then
          change = math.max(change, set(s, o1, waterfill_cap(math.min(a1 + a2, 1 + b2), b2)))
        end
        if o2 then
          change = math.max(change, set(s, o2, waterfill_cap(math.min(a1 + a2, 1 + b1), b1)))
        end
        if i1 then
          change = math.max(change, set(d, i1, waterfill_cap(math.min(1 + a2, b1 + b2), a2)))
        end
        if i2 then
          change = math.max(change, set(d, i2, waterfill_cap(math.min(1 + a1, b1 + b2), a1)))
        end
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
