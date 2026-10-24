-- Generator of exact, input-balanced, throughput-unlimited N:M splitter networks. Pure Lua,
-- no game API, deterministic. Checked offline by scripts/flow.lua (tests/unit).
--
-- Network = { n_in, n_out, splitters = { {id} }, edges = { {from = Port, to = Port} },
--             lane_splitters = { {kind = "lane_splitter", id} } (only with balance_lanes) }
-- Port = { kind = "in" | "out" | "splitter" | "lane_splitter", id, port = 1 | 2 }
--
-- Every input, output and lane splitter port has exactly one edge. A splitter has at least
-- three connected ports: for N ~= M some splitters must have one unconnected port, because a
-- splitter has as many inputs as outputs (N + 2s edge tails = M + 2s edge heads otherwise).
-- An unconnected input supplies nothing; an unconnected output is a dead end that fills
-- with a few items and then blocks.
--
-- Construction for N <= M (N > M is the transpose of M:N, reversing every edge):
-- - Core(S, b, loops): S = 2^k wires, b butterflies of k stages (stage t pairs wires w and
--   w + 2^t with one splitter). Each butterfly is a balancer: every output gets the average
--   of the inputs. Two in a row are throughput unlimited: the first spreads any inputs
--   evenly over all wires, and the second, read backwards, collects them into any outputs.
--   Core outputs that are not network outputs loop back, one to one, into core inputs.
-- - N = M: one core with S = 2^ceil(log2 N), b = 2, S - N loops.
-- - N < M: a front core for N:N (b = 1, S - N loops; none for N = 1) and then an M:M
--   core (b = 2, S - M loops; b = 1 for 1:2^k) whose M - N spare inputs are unconnected.
--   The front core keeps the input draw equal: it is an exact N:N balancer in both
--   directions (its loops are one to one), so whatever the M:M core asks from its N live
--   inputs, the front core draws equally from the network inputs. Without it, 2:3 at half
--   output capacity draws 0.5 and 1.0 from its inputs.
-- - Splitters left with no input or no output are removed, and a splitter left with one
--   input and one output becomes a plain edge; repeated until nothing changes.
--
-- With opts.balance_lanes, a lane splitter sits on every input when N <= M and on every
-- output when N > M, min(N, M) in total (docs/feasibility.md F5: either side is exact, so
-- the smaller side). The flow model passes belt totals through them.
local network = {}

network.MAX_SIDE = 16

local function ceil_pow2(x)
  local s, k = 1, 0
  while s < x do
    s, k = s * 2, k + 1
  end
  return s, k
end

local function new_builder()
  return { splitters = {}, edges = {}, next_id = 0, next_loop = 0, loop_source = {} }
end

local function add_edge(b, from, to)
  if from then
    b.edges[#b.edges + 1] = { from = from, to = to }
  end
end

-- One splitter on two wires (a source port or false). Returns the two output wires.
local function splitter(b, x, y)
  if not x and not y then
    return false, false
  end
  b.next_id = b.next_id + 1
  local id = b.next_id
  b.splitters[#b.splitters + 1] = { id = id }
  add_edge(b, x, { kind = "splitter", id = id, port = 1 })
  add_edge(b, y, { kind = "splitter", id = id, port = 2 })
  return { kind = "splitter", id = id, port = 1 }, { kind = "splitter", id = id, port = 2 }
end

-- Core with `live` input wires and `n_out` outputs on S = 2^k >= max(#live, n_out) wires.
-- Unused input slots: `S - n_out` loops, the rest unconnected. Returns n_out output wires.
local function core(b, live, n_out, butterflies)
  local S, k = ceil_pow2(math.max(#live, n_out))
  local n_loops = S - n_out
  local n_dead = S - #live - n_loops
  assert(n_dead >= 0, "core: more outputs looped than free inputs")

  -- Input layout: live inputs first, loops last, unconnected inputs in between (kept
  -- together so that splitters with two unconnected inputs drop out). Outputs: network
  -- outputs first, loops last.
  local in_layout, out_layout = {}, {}
  for w = 1, S do
    if w <= #live then
      in_layout[w] = "live"
    elseif w > S - n_loops then
      in_layout[w] = "loop"
    end
    out_layout[w] = w <= n_out and "out" or "loop"
  end

  local wires, li, loops = {}, 0, {}
  for w = 1, S do
    if in_layout[w] == "live" then
      li = li + 1
      wires[w] = live[li]
    elseif in_layout[w] == "loop" then
      b.next_loop = b.next_loop + 1
      local placeholder = { kind = "loop", id = b.next_loop, port = 1 }
      loops[#loops + 1] = placeholder
      wires[w] = placeholder
    else
      wires[w] = false
    end
  end

  for _ = 1, butterflies do
    for t = 0, k - 1 do
      local step = 2 ^ t
      for w = 0, S - 1 do
        if math.floor(w / step) % 2 == 0 then
          wires[w + 1], wires[w + step + 1] = splitter(b, wires[w + 1], wires[w + step + 1])
        end
      end
    end
  end

  local outs, li2 = {}, 0
  for w = 1, S do
    if out_layout[w] == "out" then
      outs[#outs + 1] = wires[w]
    else
      li2 = li2 + 1
      b.loop_source[loops[li2].id] = wires[w]
    end
  end
  return outs
end

local function resolve_loops(b)
  local edges = {}
  for _, ed in ipairs(b.edges) do
    local from = ed.from
    while from and from.kind == "loop" do
      from = b.loop_source[from.id]
    end
    if from then
      edges[#edges + 1] = { from = from, to = ed.to }
    end
  end
  b.edges = edges
end

-- Remove splitters with no input or no output; turn 1-in 1-out splitters into edges.
local function simplify(b)
  local changed = true
  while changed do
    changed = false
    local ins, outs = {}, {}
    for e, ed in ipairs(b.edges) do
      if ed.to.kind == "splitter" then
        ins[ed.to.id] = ins[ed.to.id] or {}
        table.insert(ins[ed.to.id], e)
      end
      if ed.from.kind == "splitter" then
        outs[ed.from.id] = outs[ed.from.id] or {}
        table.insert(outs[ed.from.id], e)
      end
    end
    for si, s in ipairs(b.splitters) do
      local i, o = ins[s.id] or {}, outs[s.id] or {}
      if #i == 0 or #o == 0 or (#i == 1 and #o == 1) then
        local drop = {}
        for _, e in ipairs(i) do
          drop[e] = true
        end
        for _, e in ipairs(o) do
          drop[e] = true
        end
        local edges = {}
        for e, ed in ipairs(b.edges) do
          if not drop[e] then
            edges[#edges + 1] = ed
          end
        end
        if #i == 1 and #o == 1 then
          local from, to = b.edges[i[1]].from, b.edges[o[1]].to
          if i[1] == o[1] then
            -- A splitter feeding only itself carries nothing.
            from = nil
          end
          if from then
            edges[#edges + 1] = { from = from, to = to }
          end
        end
        b.edges = edges
        table.remove(b.splitters, si)
        changed = true
        break
      end
    end
  end
end

local function finish(b, n_in, n_out)
  -- Renumber splitters 1..K in creation order.
  local new_id = {}
  local splitters = {}
  for i, s in ipairs(b.splitters) do
    new_id[s.id] = i
    splitters[i] = { id = i }
  end
  local function copy(p)
    if p.kind == "splitter" then
      return { kind = "splitter", id = new_id[p.id], port = p.port }
    end
    return { kind = p.kind, id = p.id, port = 1 }
  end
  local edges = {}
  for i, ed in ipairs(b.edges) do
    edges[i] = { from = copy(ed.from), to = copy(ed.to) }
  end
  return { n_in = n_in, n_out = n_out, splitters = splitters, edges = edges }
end

-- n <= m.
local function forward(n, m)
  local b = new_builder()
  local wires = {}
  for i = 1, n do
    wires[i] = { kind = "in", id = i, port = 1 }
  end
  if n < m and n > 1 then
    wires = core(b, wires, n, 1)
  end
  if m > 1 then
    -- 1:2^k is a plain splitter tree; everything else needs both butterflies (with one,
    -- loops take capacity from blocked paths and 2:4 cannot reach outputs 1 and 3).
    wires = core(b, wires, m, (n == 1 and ceil_pow2(m) == m) and 1 or 2)
  end
  for j = 1, m do
    add_edge(b, wires[j], { kind = "out", id = j, port = 1 })
  end
  resolve_loops(b)
  simplify(b)
  return finish(b, n, m)
end

local function transpose(net)
  local flip = { ["in"] = "out", out = "in" }
  local edges = {}
  for i, ed in ipairs(net.edges) do
    local from = { kind = flip[ed.to.kind] or ed.to.kind, id = ed.to.id, port = ed.to.port }
    local to = { kind = flip[ed.from.kind] or ed.from.kind, id = ed.from.id, port = ed.from.port }
    edges[i] = { from = from, to = to }
  end
  return { n_in = net.n_out, n_out = net.n_in, splitters = net.splitters, edges = edges }
end

local function add_lane_splitters(net)
  local on_inputs = net.n_in <= net.n_out
  net.lane_splitters = {}
  local count = #net.edges
  for e = 1, count do
    local ed = net.edges[e]
    local lane
    if on_inputs and ed.from.kind == "in" then
      lane = #net.lane_splitters + 1
      net.edges[#net.edges + 1] = { from = { kind = "lane_splitter", id = lane, port = 1 }, to = ed.to }
      ed.to = { kind = "lane_splitter", id = lane, port = 1 }
    elseif not on_inputs and ed.to.kind == "out" then
      lane = #net.lane_splitters + 1
      net.edges[#net.edges + 1] = { from = ed.from, to = { kind = "lane_splitter", id = lane, port = 1 } }
      ed.from = { kind = "lane_splitter", id = lane, port = 1 }
    end
    if lane then
      net.lane_splitters[lane] = { kind = "lane_splitter", id = lane }
    end
  end
end

-- Returns a Network, or nil and "invalid" / "too-large".
---@param n_in integer
---@param n_out integer
---@param opts? { balance_lanes: boolean? }
---@return table? net
---@return string? err
function network.build(n_in, n_out, opts)
  if
    type(n_in) ~= "number"
    or type(n_out) ~= "number"
    or n_in < 1
    or n_out < 1
    or n_in % 1 ~= 0
    or n_out % 1 ~= 0
  then
    return nil, "invalid"
  end
  if n_in > network.MAX_SIDE or n_out > network.MAX_SIDE then
    return nil, "too-large"
  end
  local net
  if n_in <= n_out then
    net = forward(n_in, n_out)
  else
    net = transpose(forward(n_out, n_in))
  end
  if opts and opts.balance_lanes then
    add_lane_splitters(net)
  end
  return net
end

return network
