-- Generator of exact, input-balanced, throughput-unlimited N:M splitter networks with
-- recirculation. Pure Lua, no game API, deterministic. Checked offline by scripts/flow.lua
-- (tests/unit).
--
-- Network = { n_in, n_out, splitters = { {id} }, priority = { {kind = "priority", id} },
--             edges = { {from = Port, to = Port} }, stats = { splitters, priority,
--             lane_splitters, edges },
--             lane_splitters = { {kind = "lane_splitter", id} } (only with balance_lanes) }
-- Port = { kind = "in" | "out" | "splitter" | "priority" | "lane_splitter", id, port = 1 | 2 }
-- A priority node is a splitter whose output port 1 has priority
-- (splitter_output_priority): port 1 takes what it can and only the rest goes to port 2.
--
-- Every input, output and lane splitter port has exactly one edge. A splitter has at least
-- three connected ports: for N ~= M some splitters must have one unconnected port, because a
-- splitter has as many inputs as outputs (N + 2s edge tails = M + 2s edge heads otherwise).
-- An unconnected input supplies nothing; an unconnected output is a dead end, which
-- scripts/builder.lua closes (output priority on it plus a filter for the never-existing item
-- mb-hidden-never), so it takes nothing.
--
-- Plain network (recirc = false), for N <= M (N > M is the transpose of M:N):
-- - Core(S, b): S = 2^k wires, b butterflies of k stages (stage t pairs wires w and
--   w + 2^t with one splitter). Each butterfly is a balancer: every output gets the average
--   of the inputs. Two in a row are throughput unlimited: the first spreads any inputs
--   evenly over all wires, and the second, read backwards, collects them into any outputs.
--   Core outputs that are not network outputs loop back, one to one, into core inputs.
-- - N = M: one core with S = 2^ceil(log2 N), b = 2 (b = 1 for 2:2), S - N loops.
-- - N < M: a front core for N:N (b = 1, S - N loops) and then an M:M core (b = 2,
--   S - M loops; b = 1 for 1:2^k) whose M - N spare inputs are unconnected. The front core
--   keeps the input draw equal: it is an exact N:N balancer in both directions (its loops
--   are one to one), so whatever the M:M core asks from its N live inputs, the front core
--   draws equally from the network inputs. It is left out when N is a power of two: the
--   M:M core's first log2 N stages already balance its N live wires.
--
-- Recirculating network (the default), see recirculating() below. For two outputs the
-- smaller of the plain and the recirculating network is used: the plain network's last
-- splitter already passes one output's unused share to the other.
--
-- N:1 (both modes; with one output there is nothing to redistribute) is a merge tree with a
-- priority splitter at its root, see merging() below. So even with recirc = false an N:1
-- network for N not a power of two has one priority node.
--
-- Two butterflies in a row are built as a Benes network (2k - 1 stages, see stages()): the
-- second runs in reverse, so its first stage would repeat the last stage of the first.
--
-- Splitters left with no input or no output are removed, a splitter left with one input and
-- one output becomes a plain edge, and a plain splitter whose two outputs feed the two inputs
-- of one node is dropped (fold(): that node already splits and draws equally); repeated until
-- nothing changes. The recirculating network's F runs its stages in reverse so that its last
-- stage pairs neighbouring wires, which merge_groups merges anyway: fold() removes that stage.
--
-- With opts.balance_lanes, a lane splitter sits on every input (N of them), so both lanes
-- carry equal totals before the keep-lanes network. Not on the outputs: there each output's
-- lane splitter could pass only what its two lanes bring, and with only the left input
-- lanes fed an N > M network would deliver half (0.5 per output). The lane-aware model
-- (flow.solve_lanes) checks this.
--
-- With item filters on some outputs (opts.filters, scripts/filters.lua) the network is built
-- differently, see filtered() below.
local network = {}

---@class mb.Port
---@field kind string
---@field id integer
---@field port integer

---@class mb.Edge
---@field from mb.Port
---@field to mb.Port
---@field alive boolean?

---@class mb.Network
---@field n_in integer
---@field n_out integer
---@field splitters { id: integer, filter: string?, prio: string? }[] filter: a filter splitter
---  (filtered networks): that item goes out of the `prio` side ("left": port 1)
---@field priority { kind: string, id: integer }[]
---@field edges mb.Edge[]
---@field lane_splitters { kind: string, id: integer, filter: string?, prio: string? }[]?
---@field filtered boolean? built with item filters (see filtered())
---@field stats { splitters: integer, priority: integer, lane_splitters: integer, edges: integer }?

---@type table<string, boolean>
local INTERNAL = { splitter = true, priority = true }

local function ceil_pow2(x)
  local s, k = 1, 0
  while s < x do
    s, k = s * 2, k + 1
  end
  return s, k
end

local function new_builder()
  return { nodes = {}, edges = {}, next_id = { splitter = 0, priority = 0 }, next_loop = 0, loop_source = {} }
end

local function add_edge(b, from, to)
  if from then
    b.edges[#b.edges + 1] = { from = from, to = to }
  end
end

local function new_node(b, kind)
  local id = b.next_id[kind] + 1
  b.next_id[kind] = id
  b.nodes[#b.nodes + 1] = { kind = kind, id = id }
  return id
end

-- One splitter (or priority splitter) on two wires (a source port or false). Returns the two
-- output wires.
local function node(b, kind, x, y)
  if not x and not y then
    return false, false
  end
  local id = new_node(b, kind)
  add_edge(b, x, { kind = kind, id = id, port = 1 })
  add_edge(b, y, { kind = kind, id = id, port = 2 })
  return { kind = kind, id = id, port = 1 }, { kind = kind, id = id, port = 2 }
end

-- One butterfly stage: wires w and w + 2^t share a splitter.
local function stage(b, wires, S, t)
  local step = 2 ^ t
  for w = 0, S - 1 do
    if math.floor(w / step) % 2 == 0 then
      wires[w + 1], wires[w + step + 1] = node(b, "splitter", wires[w + 1], wires[w + step + 1])
    end
  end
end

-- Stage order of a core on 2^k wires. One butterfly: t = 0 .. k-1 (reversed for a transposed
-- core). Two butterflies are a Benes network: the second butterfly runs in the opposite order, so
-- its first stage would pair the same wires as the last stage of the first one; two splitters in
-- a row on the same pair of wires act as one, so that stage is built once (2k - 1 stages).
local function stages(k, butterflies, reversed)
  local list = {}
  for t = 0, k - 1 do
    list[#list + 1] = t
  end
  if butterflies == 2 then
    for t = k - 2, 0, -1 do
      list[#list + 1] = t
    end
  end
  if reversed then
    local r = {}
    for i = #list, 1, -1 do
      r[#r + 1] = list[i]
    end
    list = r
  end
  return list
end

-- A wire whose source is set later in b.loop_source (resolve_loops).
local function loop_wire(b)
  b.next_loop = b.next_loop + 1
  return { kind = "loop", id = b.next_loop, port = 1 }
end

local function input_wires(n)
  local wires = {}
  for i = 1, n do
    wires[i] = { kind = "in", id = i, port = 1 }
  end
  return wires
end

-- Core with `live` input wires and `n_out` outputs on S = 2^k >= max(#live, n_out) wires.
-- Unused input slots: `S - n_out` loops, the rest unconnected. Returns n_out output wires.
local function core(b, live, n_out, butterflies, reversed)
  local S, k = ceil_pow2(math.max(#live, n_out))
  local n_loops = S - n_out
  assert(S - #live - n_loops >= 0, "core: more outputs looped than free inputs")

  -- Live inputs first, loops last, unconnected inputs in between (kept together so that
  -- splitters with two unconnected inputs drop out). Outputs: network outputs first.
  local wires, loops = {}, {}
  for w = 1, S do
    if w <= #live then
      wires[w] = live[w]
    elseif w > S - n_loops then
      local lw = loop_wire(b)
      loops[#loops + 1] = lw
      wires[w] = lw
    else
      wires[w] = false
    end
  end
  for _, t in ipairs(stages(k, butterflies, reversed)) do
    stage(b, wires, S, t)
  end
  local outs = {}
  for w = 1, S do
    if w <= n_out then
      outs[w] = wires[w]
    else
      b.loop_source[loops[w - n_out].id] = wires[w]
    end
  end
  return outs
end

-- The transpose of core(b, <n_out wires>, #live, butterflies), built directly: #live >= n_out
-- inputs, S - #live loops, stages in reverse order, and the #live - n_out outputs after the
-- network outputs left unconnected.
local function transposed_core(b, live, n_out, butterflies)
  local S, k = ceil_pow2(#live)
  assert(n_out <= #live, "transposed core: more outputs than inputs")
  local wires, loops = {}, {}
  for w = 1, S do
    if w <= #live then
      wires[w] = live[w]
    else
      local lw = loop_wire(b)
      loops[#loops + 1] = lw
      wires[w] = lw
    end
  end
  for _, t in ipairs(stages(k, butterflies, true)) do
    stage(b, wires, S, t)
  end
  local outs = {}
  for w = 1, S do
    if w <= n_out then
      outs[w] = wires[w]
    elseif w > #live then
      b.loop_source[loops[w - #live].id] = wires[w]
    end
  end
  return outs
end

local function resolve_loops(b)
  local edges = {}
  for _, ed in ipairs(b.edges) do
    local from, hops = ed.from, 0
    while from and from.kind == "loop" do
      from = b.loop_source[from.id]
      hops = hops + 1
      assert(hops <= b.next_loop, "loop wires form a cycle")
    end
    if from then
      ed.from = from
      edges[#edges + 1] = ed
    end
  end
  b.edges = edges
end

-- Remove nodes with no input or no output; turn 1-in 1-out nodes into edges. Worklist, so
-- large networks simplify in linear time.
local function simplify(b)
  ---@type table<string, table<integer, table<integer, mb.Edge?>>>
  local ins = { splitter = {}, priority = {} }
  ---@type table<string, table<integer, table<integer, mb.Edge?>>>
  local outs = { splitter = {}, priority = {} }
  for _, n in ipairs(b.nodes) do
    ins[n.kind][n.id], outs[n.kind][n.id] = {}, {}
  end
  for _, ed in ipairs(b.edges) do
    ed.alive = true
    local f, d = ed.from, ed.to
    if INTERNAL[f.kind] then
      outs[f.kind][f.id][f.port] = ed
    end
    if INTERNAL[d.kind] then
      ins[d.kind][d.id][d.port] = ed
    end
  end
  ---@type table<string, table<integer, boolean>>
  local removed = { splitter = {}, priority = {} }
  ---@type mb.Port[]
  local queue = {}
  local qi = 1
  for _, n in ipairs(b.nodes) do
    queue[#queue + 1] = n
  end
  while qi <= #queue do
    local n = queue[qi] --[[@as mb.Port]]
    qi = qi + 1
    if not removed[n.kind][n.id] then
      local i, o = ins[n.kind][n.id], outs[n.kind][n.id]
      local ni = (i[1] and 1 or 0) + (i[2] and 1 or 0)
      local no = (o[1] and 1 or 0) + (o[2] and 1 or 0)
      if ni == 0 or no == 0 then
        removed[n.kind][n.id] = true
        for p = 1, 2 do
          local e = i[p]
          if e then
            e.alive = false
            local f = e.from
            if INTERNAL[f.kind] then
              outs[f.kind][f.id][f.port] = nil
              queue[#queue + 1] = f
            end
          end
          e = o[p]
          if e then
            e.alive = false
            local d = e.to
            if INTERNAL[d.kind] then
              ins[d.kind][d.id][d.port] = nil
              queue[#queue + 1] = d
            end
          end
        end
      elseif ni == 1 and no == 1 then
        removed[n.kind][n.id] = true
        local e_in = (i[1] or i[2]) --[[@as mb.Edge]]
        local e_out = (o[1] or o[2]) --[[@as mb.Edge]]
        if e_in == e_out then
          -- A node feeding only itself carries nothing.
          e_in.alive = false
        else
          e_out.alive = false
          local d = e_out.to
          e_in.to = d
          if INTERNAL[d.kind] then
            ins[d.kind][d.id][d.port] = e_in
          end
        end
      end
    end
  end
  local nodes, edges = {}, {}
  for _, n in ipairs(b.nodes) do
    if not removed[n.kind][n.id] then
      nodes[#nodes + 1] = n
    end
  end
  for _, ed in ipairs(b.edges) do
    if ed.alive then
      ed.alive = nil
      edges[#edges + 1] = ed
    end
  end
  b.nodes, b.edges = nodes, edges
end

-- A plain splitter whose two outputs feed the two inputs of one node does nothing that node
-- does not do anyway (that node splits and draws equally on its own): its inputs go straight
-- to that node. Returns true if it removed any.
local function fold(b)
  ---@type table<integer, table<integer, mb.Edge>>
  local out_of = {}
  for _, ed in ipairs(b.edges) do
    local f = ed.from
    if f.kind == "splitter" then
      out_of[f.id] = out_of[f.id] or {}
      out_of[f.id][f.port] = ed
    end
  end
  local drop, target = {}, {}
  for _, n in ipairs(b.nodes) do
    ---@type table<integer, mb.Edge>?
    local o = nil
    if n.kind == "splitter" then
      o = out_of[n.id]
    end
    ---@type mb.Port?, mb.Port?
    local t1, t2 = nil, nil
    if o and o[1] and o[2] then
      t1, t2 = o[1].to, o[2].to
    end
    if t1 and t2 and INTERNAL[t1.kind] and t1.kind == t2.kind and t1.id == t2.id
      and not target[n.id] and not (t1.kind == "splitter" and drop[t1.id]) then
      drop[n.id] = { [1] = t1, [2] = t2 }
      if t1.kind == "splitter" then
        target[t1.id] = true
      end
    end
  end
  if next(drop) == nil then
    return false
  end
  local nodes, edges = {}, {}
  for _, n in ipairs(b.nodes) do
    if not (n.kind == "splitter" and drop[n.id]) then
      nodes[#nodes + 1] = n
    end
  end
  for _, ed in ipairs(b.edges) do
    local f, d = ed.from, ed.to
    if not (f.kind == "splitter" and drop[f.id]) then
      if d.kind == "splitter" and drop[d.id] then
        ed.to = drop[d.id][d.port]
      end
      edges[#edges + 1] = ed
    end
  end
  b.nodes, b.edges = nodes, edges
  return true
end

-- Renumbers splitters and priority splitters 1..K in creation order.
---@return mb.Network
local function finish(b, n_in, n_out)
  resolve_loops(b)
  simplify(b)
  while fold(b) do
    simplify(b)
  end
  local new_id, splitters, priority = { splitter = {}, priority = {} }, {}, {}
  for _, n in ipairs(b.nodes) do
    if n.kind == "splitter" then
      splitters[#splitters + 1] = { id = #splitters + 1 }
      new_id.splitter[n.id] = #splitters
    else
      priority[#priority + 1] = { kind = "priority", id = #priority + 1 }
      new_id.priority[n.id] = #priority
    end
  end
  -- Every port table belongs to exactly one edge (wires are used once, and simplify hands
  -- a dropped edge's target to the surviving edge), so it is renumbered in place once.
  for _, ed in ipairs(b.edges) do
    local f, d = ed.from, ed.to
    if INTERNAL[f.kind] then
      f.id = new_id[f.kind][f.id]
    end
    if INTERNAL[d.kind] then
      d.id = new_id[d.kind][d.id]
    end
  end
  return { n_in = n_in, n_out = n_out, splitters = splitters, priority = priority, edges = b.edges }
end

-- Plain n:m, n <= m.
---@return mb.Network
local function forward(n, m)
  local b = new_builder()
  local wires = input_wires(n)
  if n < m and ceil_pow2(n) ~= n then
    -- Reversed, so its last stage pairs neighbouring wires like the first stage of the M:M
    -- core: fold() drops one of the two.
    wires = core(b, wires, n, 1, true)
  end
  if m > 1 then
    -- 1:2^k is a plain splitter tree and 2:2 is one splitter; everything else needs both
    -- butterflies (with one, loops take capacity from blocked paths and 2:4 cannot reach
    -- outputs 1 and 3).
    wires = core(b, wires, m, ((n == 1 and ceil_pow2(m) == m) or m == 2) and 1 or 2)
  end
  for j = 1, m do
    add_edge(b, wires[j], { kind = "out", id = j, port = 1 })
  end
  return finish(b, n, m)
end

---@return mb.Network
local function transpose(net)
  local flip = { ["in"] = "out", out = "in" }
  local edges = {}
  for i, ed in ipairs(net.edges) do
    local from = { kind = flip[ed.to.kind] or ed.to.kind, id = ed.to.id, port = ed.to.port }
    local to = { kind = flip[ed.from.kind] or ed.from.kind, id = ed.from.id, port = ed.from.port }
    edges[i] = { from = from, to = to }
  end
  return { n_in = net.n_out, n_out = net.n_in, splitters = net.splitters, priority = {}, edges = edges }
end

---@return mb.Network
local function plain(n, m)
  if n <= m then
    return forward(n, m)
  end
  return transpose(forward(m, n))
end

-- Merges `wires` into `count` contiguous groups, each through a binary tree of splitters
-- with one unconnected output. Returns the merged wires.
local function merge_groups(b, wires, count)
  if count >= #wires then
    return wires
  end
  local merged = {}
  for g = 1, count do
    local first = math.floor((g - 1) * #wires / count) + 1
    local last = math.floor(g * #wires / count)
    local group = {}
    for w = first, last do
      group[#group + 1] = wires[w]
    end
    while #group > 1 do
      local next_group = {}
      for i = 1, #group, 2 do
        if group[i + 1] then
          next_group[#next_group + 1] = node(b, "splitter", group[i], group[i + 1])
        else
          next_group[#next_group + 1] = group[i]
        end
      end
      group = next_group
    end
    merged[g] = group[1]
  end
  return merged
end

-- How many lines F's n outputs can be merged into for m outputs: in free flow F's outputs
-- carry equal flows and the total is at most m, so a group of g lines carries at most
-- g * m / n. The smallest count L >= m whose largest group ceil(n / L) has g * m <= n.
local function group_count(n, m)
  for count = m, n - 1 do
    if math.ceil(n / count) * m <= n then
      return count
    end
  end
  return n
end

-- Recirculating n:m (m >= 2):
-- - F: the inputs pass an exact n:n balancer (one butterfly, one-to-one loops; left out
--   for n = 1).
-- - G: F's n outputs and m overflow wires feed a plain (n + m):m network.
-- - Every G output j passes a priority splitter: port 1 is network output j, port 2 (what
--   output j does not take) is overflow wire j, back into G.
-- G spreads its inputs equally over all outputs whatever their mix, so an output that takes
-- less than its share sends the rest round again and the others share it equally (water
-- filling). The overflow wires are G inputs that may be starved, so G alone draws its live
-- inputs unequally under backpressure (measured in the engine: 3:5 with 2 outputs open drew
-- 45 / 22.5 / 22.5). F is an exact balancer in both directions whatever its outputs ask
-- for, so it draws the network inputs equally.
---@return mb.Network
local function recirculating(n, m)
  local b = new_builder()
  local wires = input_wires(n)
  if n > 1 then
    -- Last stage t = 0 pairs neighbouring wires, as the first level of merge_groups does:
    -- fold() then drops those splitters.
    wires = core(b, wires, n, 1, true)
  end
  ---@type (mb.Port|false)[]
  wires = merge_groups(b, wires, group_count(n, m))
  local lines = #wires
  local overflow = {}
  for j = 1, m do
    overflow[j] = loop_wire(b)
    wires[lines + j] = overflow[j]
  end
  -- G is the transpose of plain m:(n + m), built in place.
  local g = transposed_core(b, wires, m, 2)
  if ceil_pow2(m) ~= m then
    g = transposed_core(b, g, m, 1)
  end
  for j = 1, m do
    local out, back = node(b, "priority", g[j], false)
    add_edge(b, out, { kind = "out", id = j, port = 1 })
    b.loop_source[overflow[j].id] = back
  end
  return finish(b, n, m)
end

-- n:1: a balanced merge tree over S = 2^k leaves (n inputs, S - n loop leaves); the root
-- passes a priority splitter whose overflow feeds the loop leaves through a splitter tree.
---@return mb.Network
local function merging(n)
  local b = new_builder()
  local S = ceil_pow2(n)
  local wires = input_wires(n)
  local loops = {}
  for w = n + 1, S do
    loops[#loops + 1] = loop_wire(b)
    wires[w] = loops[#loops]
  end
  while #wires > 2 do
    local next_wires = {}
    for i = 1, #wires, 2 do
      next_wires[#next_wires + 1] = node(b, "splitter", wires[i], wires[i + 1])
    end
    wires = next_wires
  end
  local root, back = node(b, #loops > 0 and "priority" or "splitter", wires[1], wires[2])
  if #loops > 0 then
    local dist = { back }
    while #dist < #loops do
      local next_dist = {}
      for _, w in ipairs(dist) do
        local x, y = node(b, "splitter", w, false)
        next_dist[#next_dist + 1] = x
        next_dist[#next_dist + 1] = y
      end
      dist = next_dist
    end
    for i, lw in ipairs(loops) do
      b.loop_source[lw.id] = dist[i]
    end
  end
  add_edge(b, root, { kind = "out", id = 1, port = 1 })
  return finish(b, n, 1)
end

local function add_lane_splitters(net)
  net.lane_splitters = {}
  local count = #net.edges
  for e = 1, count do
    local ed = net.edges[e]
    if ed.from.kind == "in" then
      local lane = #net.lane_splitters + 1
      net.edges[#net.edges + 1] = { from = { kind = "lane_splitter", id = lane, port = 1 }, to = ed.to }
      ed.to = { kind = "lane_splitter", id = lane, port = 1 }
      net.lane_splitters[lane] = { kind = "lane_splitter", id = lane }
    end
  end
end

-- The unfiltered network without lane splitters.
---@param n_in integer
---@param n_out integer
---@param recirc boolean
---@return mb.Network
local function base(n_in, n_out, recirc)
  ---@type mb.Network
  local net
  if recirc and n_out >= 3 then
    net = recirculating(n_in, n_out)
  elseif recirc and n_out == 2 then
    -- The plain n:2 network ends in one splitter on both outputs, and a splitter already
    -- gives what one output does not take to the other: it recirculates by itself. Keep
    -- whichever is smaller (the plain one except for sizes just above a power of two,
    -- such as 17:2).
    local a, b = plain(n_in, 2), recirculating(n_in, 2)
    net = (#b.splitters + #b.priority < #a.splitters + #a.priority) and b or a
  elseif n_out == 1 then
    net = merging(n_in)
  else
    net = plain(n_in, n_out)
  end
  return net
end

-- Filtered network (opts.filters, one mb.FilterSpec or false per output; scripts/filters.lua).
--
-- Sinks: an output without a lane filter is one sink (j, 0); an output with one has a sink per
-- lane that has an item: (j, 1) left, (j, 2) right. Every item named in any filter gets the set
-- of sinks that take it: the sinks whose whitelist (or lane slot) names it if there are any
-- (exclusive), else every whole sink without a whitelist whose blacklist does not name it. Items
-- not named anywhere (the rest) go to every whole sink without a whitelist. Named items with the
-- same sink set as another named item form one class, and a named item whose set is the rest's
-- joins the rest; each class keeps the order of its first item (items sorted by name).
--
-- Built from parts that are each exact (nothing here is simplified across parts):
-- - every network input passes (its lane splitter with balance_lanes, then) a chain of filter
--   splitters, one per item of every class but the rest: port 1 (filtered, priority) takes the
--   item, port 2 the others and feeds the next. A class with several items merges its ports 1
--   per input with a merge tree. What is left after the chain is the rest.
-- - every class with sinks gets its own n:k network (base(), the group's recirc setting) from the
--   n streams of that class to its k sinks: within a class every sink gets an equal share, and
--   recirculation passes unused shares between them.
-- - every whole sink merges the wires of the classes it is in (merge tree) into its output. A lane
--   sink passes a lane splitter whose filter is its item, with output priority on its lane (the
--   filter item goes to the priority lane: measured), and the two lanes of an output merge in a
--   splitter, which keeps lanes apart.
-- A class with no sink leaves its filtered port (or the end of the chain, for the rest)
-- unconnected: those items wait in front of it and block that input, as a vanilla filter
-- splitter whose filtered side is full.
-- Merge splitters use only output port 1; scripts/builder.lua closes port 2. Filter splitters
-- carry `filter` and `prio` and are never closed.
---@param n integer
---@param m integer
---@param specs (mb.FilterSpec|false)[]
---@param opts { balance_lanes: boolean?, recirc: boolean? }
---@return mb.Network
local function filtered(n, m, specs, opts)
  local recirc = opts.recirc ~= false
  local splitters, priority, lanes, edges = {}, {}, {}, {}
  local function edge(from, to)
    edges[#edges + 1] = { from = from, to = to }
  end
  local function port(kind, id, p)
    return { kind = kind, id = id, port = p }
  end
  local function new_splitter(filter, prio)
    local id = #splitters + 1
    splitters[id] = { id = id, filter = filter, prio = prio }
    return id
  end
  local function new_lane(filter, prio)
    local id = #lanes + 1
    lanes[id] = { kind = "lane_splitter", id = id, filter = filter, prio = prio }
    return id
  end
  -- Merges the source ports `wires` into one (a tree of splitters, output port 1 only).
  local function merge(wires)
    while #wires > 1 do
      local next_wires = {}
      for i = 1, #wires, 2 do
        if wires[i + 1] then
          local id = new_splitter()
          edge(wires[i], port("splitter", id, 1))
          edge(wires[i + 1], port("splitter", id, 2))
          next_wires[#next_wires + 1] = port("splitter", id, 1)
        else
          next_wires[#next_wires + 1] = wires[i]
        end
      end
      wires = next_wires
    end
    return wires[1]
  end

  -- sinks and the sink set of every named item
  local sinks, sink_of = {}, {}
  local function sink(j, lane)
    local key = j .. ":" .. lane
    if not sink_of[key] then
      sinks[#sinks + 1] = { j = j, lane = lane }
      sink_of[key] = #sinks
    end
    return sink_of[key]
  end
  for j = 1, m do
    local s = specs[j]
    if s and s.lanes then
      if s.left then
        sink(j, 1)
      end
      if s.right then
        sink(j, 2)
      end
    else
      sink(j, 0)
    end
  end
  local named, seen = {}, {}
  for j = 1, m do
    local s = specs[j]
    if s then
      local list = s.items or {}
      if s.lanes then
        list = {}
        list[#list + 1] = s.left
        list[#list + 1] = s.right
      end
      for _, x in ipairs(list) do
        if not seen[x] then
          seen[x] = true
          named[#named + 1] = x
        end
      end
    end
  end
  table.sort(named)
  local function set_key(list)
    table.sort(list)
    return table.concat(list, ",")
  end
  local rest = {}
  for j = 1, m do
    local s = specs[j]
    if not s or (not s.lanes and s.exclude) then
      rest[#rest + 1] = sink_of[j .. ":0"]
    end
  end
  local rest_key = set_key(rest)
  local classes, class_of = {}, {}
  for _, x in ipairs(named) do
    local claim, open = {}, {}
    for j = 1, m do
      local s = specs[j]
      if s and s.lanes then
        if s.left == x then
          claim[#claim + 1] = sink_of[j .. ":1"]
        end
        if s.right == x then
          claim[#claim + 1] = sink_of[j .. ":2"]
        end
      elseif s and not s.exclude then
        for _, y in ipairs(s.items or {}) do
          if y == x then
            claim[#claim + 1] = sink_of[j .. ":0"]
          end
        end
      else
        local excluded = false
        for _, y in ipairs(s and s.items or {}) do
          if y == x then
            excluded = true
          end
        end
        if not excluded then
          open[#open + 1] = sink_of[j .. ":0"]
        end
      end
    end
    local list = #claim > 0 and claim or open
    local key = set_key(list)
    if key ~= rest_key then
      if not class_of[key] then
        classes[#classes + 1] = { items = {}, sinks = list }
        class_of[key] = #classes
      end
      local c = classes[class_of[key]]
      c.items[#c.items + 1] = x
    end
  end

  -- per input: the chain of filter splitters, giving the stream of every class
  local streams = {} -- streams[c][i]; c = #classes + 1 is the rest
  for c = 1, #classes + 1 do
    streams[c] = {}
  end
  for i = 1, n do
    local wire = port("in", i, 1)
    if opts.balance_lanes then
      local id = new_lane()
      edge(wire, port("lane_splitter", id, 1))
      wire = port("lane_splitter", id, 1)
    end
    for c, cl in ipairs(classes) do
      local parts = {}
      for _, x in ipairs(cl.items) do
        local id = new_splitter(x, "left")
        edge(wire, port("splitter", id, 1))
        parts[#parts + 1] = port("splitter", id, 1)
        wire = port("splitter", id, 2)
      end
      if #cl.sinks > 0 then
        streams[c][i] = merge(parts)
      end
    end
    streams[#classes + 1][i] = wire
  end

  -- per class with sinks: its own network into the wires of its sinks
  local sink_wires = {}
  for k = 1, #sinks do
    sink_wires[k] = {}
  end
  local all = {}
  for c, cl in ipairs(classes) do
    all[c] = cl.sinks
  end
  all[#classes + 1] = rest
  for c = 1, #classes + 1 do
    local list = all[c] or {}
    if #list > 0 then
      local sub = base(n, #list, recirc)
      local s0, p0 = #splitters, #priority
      for _, sp in ipairs(sub.splitters) do
        splitters[#splitters + 1] = { id = sp.id + s0 }
      end
      for _, pr in ipairs(sub.priority or {}) do
        priority[#priority + 1] = { kind = "priority", id = pr.id + p0 }
      end
      local function moved(p)
        if p.kind == "splitter" then
          return port("splitter", p.id + s0, p.port)
        elseif p.kind == "priority" then
          return port("priority", p.id + p0, p.port)
        end
        return port(p.kind, p.id, p.port)
      end
      for _, ed in ipairs(sub.edges) do
        local from = ed.from.kind == "in" and streams[c][ed.from.id] or moved(ed.from)
        if ed.to.kind == "out" then
          local w = sink_wires[list[ed.to.id]]
          w[#w + 1] = from
        else
          edge(from, moved(ed.to))
        end
      end
    end
  end

  -- every output: its whole sink's wires merged, or its lane sinks
  for j = 1, m do
    local s = specs[j]
    local out = port("out", j, 1)
    if s and s.lanes then
      local sides = {}
      local items = { s.left or false, s.right or false }
      for lane = 1, 2 do
        local x = items[lane]
        if x then
          local id = new_lane(x, lane == 1 and "left" or "right")
          edge(merge(sink_wires[sink_of[j .. ":" .. lane]]), port("lane_splitter", id, 1))
          sides[#sides + 1] = port("lane_splitter", id, 1)
        end
      end
      edge(merge(sides), out)
    else
      edge(merge(sink_wires[sink_of[j .. ":0"]]), out)
    end
  end
  return { n_in = n, n_out = m, splitters = splitters, priority = priority, lane_splitters = lanes, edges = edges,
    filtered = true }
end

-- Returns a Network, or nil and "invalid". Any size builds.
-- opts.recirc (default true): recirculate every output's unused share (needs n_out >= 2;
-- with one output there is nothing to redistribute). opts.balance_lanes: lane splitters.
-- opts.filters: one mb.FilterSpec (or false) per output; with any filter the network is a
-- filtered one (see filtered() above), else the same as without.
---@param n_in integer
---@param n_out integer
---@param opts? { balance_lanes: boolean?, recirc: boolean?, filters: (mb.FilterSpec|false)[]? }
---@return mb.Network? net
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
  opts = opts or {}
  local net
  local any = false
  for j = 1, n_out do
    if opts.filters and opts.filters[j] then
      any = true
    end
  end
  if any then
    net = filtered(n_in, n_out, opts.filters --[[@as (mb.FilterSpec|false)[] ]], opts)
  else
    net = base(n_in, n_out, opts.recirc ~= false)
    if opts.balance_lanes then
      add_lane_splitters(net)
    end
  end
  net.stats = {
    splitters = #net.splitters,
    priority = #net.priority,
    lane_splitters = #(net.lane_splitters or {}),
    edges = #net.edges,
  }
  return net
end

return network
