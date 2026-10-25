-- Places a generated network (scripts/network.lua) on the hidden surface, rebuilds it with its
-- items carried over, and removes it.
--
-- Every node gets a cell on a grid inside the network's region. A cell is CELL_W x CELL_H tiles,
-- all nodes facing east:
--   splitter, priority  x0: its two input tiles, x0 + 1: the splitter, x0 + 2: its two output
--                       tiles (port 1 on row y0, port 2 on row y0 + 1). A priority node is the
--                       same splitter with splitter_output_priority = "left": for a splitter
--                       facing east, left is north, so port 1 (row y0) has priority
--   lane splitter       x0: input tile, x0 + 1: the lane splitter, x0 + 2: output tile (row y0)
--   pass-through        an edge from a network input straight to an output (1:1): x0 and x0 + 1
-- Column x0 + 3 and row y0 + 2 stay empty, so no two cells touch.
--
-- Every network edge is one pair of hidden linked belts (docs/feasibility.md F1, F2): an
-- input-type linked belt on the source node's output tile, linked to an output-type linked belt
-- on the target node's input tile. Network inputs and outputs are the unlinked halves:
--   placed.inputs[i]   the output-type linked belt that feeds input i into the network; the
--                      visible side links an input-type linked belt to it
--   placed.outputs[j]  the input-type linked belt that output j leaves the network through;
--                      the visible side links an output-type linked belt to it
-- An unconnected splitter input tile stays empty. An unconnected splitter output tile stays
-- empty too: that output is a dead end. A plain splitter with one dead-end output gets output
-- priority on the dead end with a splitter filter for `mb-hidden-never`, an item that never
-- exists: only matching items may take the filtered side, so no item ever enters the dead end,
-- not even while the connected output is blocked. Without this, a splitter fills its dead end
-- (alternating in free flow, or when its live output backs up) and those items stay there until
-- the network is rebuilt or removed (measured: 12 left in a 3:1 after draining a shrink).
--
-- The buffer (a strip of BUFFER_W tiles right of the grid) holds what a rebuild could not put
-- back on the belts:
--   x0: the buffer chest (row y0 + 1); x0 + 1: placed.inputs[1] (row y0) and a loader that
--   empties the chest (row y0 + 1); x0 + 2: a merge splitter; x0 + 3: an input-type linked belt
--   (row y0) linked to the network's own input 1. The merge splitter's lower output is a dead
--   end, closed with the same filter as any other dead end.
-- After a big shrink the chest can be very large; builder.compact shrinks it back once empty.
-- So input 1 and the buffer share one network input: while the buffer holds items, input 1 is
-- drawn at up to half a belt; once it is empty, input 1 runs at full speed and the network is
-- unchanged. (A separate network input for the buffer would sit empty in the steady state, and
-- an empty input breaks equal input draw in a balancer.)
local surface = require("scripts.surface")

local builder = {}

local CELL_W, CELL_H = 4, 3
local BUFFER_W = 5
local EAST = defines.direction.east
local NEVER = "mb-hidden-never"
local TIER_BELTS = {
  basic = "transport-belt",
  fast = "fast-transport-belt",
  express = "express-transport-belt",
  turbo = "turbo-transport-belt",
}

-- Largest buffer (set_inventory_size_override takes a uint16). A field so a test can lower it.
builder.max_buffer_slots = 65535
-- Largest script inventory builder.take creates (create_inventory takes a uint16). Never sized by
-- item count: a full 96:96 holds about 65 000 single items. A field so a test can lower it.
builder.max_take_slots = 65535

-- Test hook (tests/game/placement.lua): when set to k, place fails while creating entity k.
---@type integer?
builder.fail_after = nil

---@param net mb.Network
---@return integer cols, integer rows
local function grid(net)
  local direct = 0
  for _, ed in ipairs(net.edges) do
    if ed.from.kind == "in" and ed.to.kind == "out" then
      direct = direct + 1
    end
  end
  local cells = #net.splitters + #(net.priority or {}) + #(net.lane_splitters or {}) + direct
  local cols = math.max(1, math.ceil(math.sqrt(cells)))
  return cols, math.max(1, math.ceil(cells / cols))
end

-- Size in tiles of the rectangle `place` reserves for `net`.
---@param net mb.Network
---@return integer w, integer h
function builder.size(net)
  local cols, rows = grid(net)
  return cols * CELL_W + BUFFER_W, math.max(rows * CELL_H, CELL_H)
end

-- Work units (about one microsecond each on a desktop, from the 64:64 rebuild hitch,
-- docs/benchmarks.md) that the staged rebuild (scripts/balancer.lua) charges against its budget
-- per tick: generating a network and planning it (per planned operation), creating an entity,
-- linking a linked-belt pair, moving one item, destroying an entity. Deterministic counts, never
-- wall-clock time, so every peer of a multiplayer game does the same work in the same tick.
builder.COST = { generate = 5, plan = 2, create = 14, link = 2, item = 12, destroy = 9 }

-- The operations that place `net` with its region at `origin`, in order: { name, position,
-- direction, type?, prio?, filter?, dead? } creates an entity (its index in placed.entities is the
-- count of creates so far), { link = { a, b } } links entity a (input-type) to entity b. Also the
-- entity indices of the network inputs and outputs and of the buffer chest. Pure: nothing is
-- created, so a placement can run over several ticks (builder.start, builder.advance).
---@param net mb.Network
---@param tier string
---@param origin {x: integer, y: integer}
local function plan(net, tier, origin)
  local cols = grid(net)
  local lb_name = "mb-hidden-linked-belt-" .. tier
  local ops = {}
  local count = 0
  local function create(t)
    ops[#ops + 1] = t
    count = count + 1
    return count
  end

  -- Top-left tile of each cell, in order: splitters, priority splitters, lane splitters,
  -- pass-throughs.
  local next_cell = 0
  local function cell()
    local c = next_cell
    next_cell = next_cell + 1
    return origin.x + (c % cols) * CELL_W, origin.y + math.floor(c / cols) * CELL_H
  end

  -- Tile centre of each node's ports: in_tile[kind][id][port], out_tile[kind][id][port].
  ---@type table<string, table<integer, number[][]>>
  local in_tile = { splitter = {}, priority = {}, lane_splitter = {} }
  ---@type table<string, table<integer, number[][]>>
  local out_tile = { splitter = {}, priority = {}, lane_splitter = {} }
  -- Connected output ports of each plain splitter, for the dead-end priority.
  local outs = {}
  for _, ed in ipairs(net.edges) do
    if ed.from.kind == "splitter" then
      outs[ed.from.id] = outs[ed.from.id] or {}
      outs[ed.from.id][ed.from.port] = true
    end
  end
  local function splitter_cell(kind, id)
    local x, y = cell()
    local t = { name = "mb-hidden-splitter-" .. tier, position = { x + 1.5, y + 1 }, direction = EAST }
    if kind == "priority" then
      t.prio = "left"
    else
      local o = outs[id] or {}
      if o[1] ~= o[2] then
        t.prio = o[1] and "right" or "left"
        t.filter = true
        t.dead = true
      end
    end
    create(t)
    in_tile[kind][id] = { { x + 0.5, y + 0.5 }, { x + 0.5, y + 1.5 } }
    out_tile[kind][id] = { { x + 2.5, y + 0.5 }, { x + 2.5, y + 1.5 } }
  end
  for _, sp in ipairs(net.splitters) do
    splitter_cell("splitter", sp.id)
  end
  for _, pr in ipairs(net.priority or {}) do
    splitter_cell("priority", pr.id)
  end
  for _, ls in ipairs(net.lane_splitters or {}) do
    local x, y = cell()
    create({ name = "mb-hidden-lane-splitter-" .. tier, position = { x + 1.5, y + 0.5 }, direction = EAST })
    in_tile.lane_splitter[ls.id] = { { x + 0.5, y + 0.5 } }
    out_tile.lane_splitter[ls.id] = { { x + 2.5, y + 0.5 } }
  end

  local function linked_belt(position, type)
    return create({ name = lb_name, position = position, direction = EAST, type = type })
  end

  local inputs, outputs = {}, {}
  for _, ed in ipairs(net.edges) do
    local from, to = ed.from, ed.to
    local tail, head -- input-type on the source side, output-type on the target side
    if from.kind == "in" and to.kind == "out" then
      local x, y = cell()
      head = linked_belt({ x + 0.5, y + 0.5 }, "output")
      tail = linked_belt({ x + 1.5, y + 0.5 }, "input")
    else
      if from.kind ~= "in" then
        tail = linked_belt((out_tile[from.kind] --[[@as table]])[from.id][from.port], "input")
      end
      if to.kind ~= "out" then
        head = linked_belt((in_tile[to.kind] --[[@as table]])[to.id][to.port], "output")
      end
      if tail and head then
        ops[#ops + 1] = { link = { tail, head } }
      end
    end
    if from.kind == "in" then
      inputs[from.id] = head
    end
    if to.kind == "out" then
      outputs[to.id] = tail
    end
  end

  -- The buffer strip, merged into input 1.
  local bx, by = origin.x + cols * CELL_W, origin.y
  local buffer = create({ name = "mb-hidden-buffer", position = { bx + 0.5, by + 1.5 } })
  local head = linked_belt({ bx + 1.5, by + 0.5 }, "output")
  create({ name = "mb-hidden-loader-" .. tier, position = { bx + 1.5, by + 1.5 }, direction = EAST, type = "output" })
  create({ name = "mb-hidden-splitter-" .. tier, position = { bx + 2.5, by + 1 }, direction = EAST, prio = "right", filter = true, dead = true })
  local tail = linked_belt({ bx + 3.5, by + 0.5 }, "input")
  if not inputs[1] then
    error("builder: network has no input 1")
  end
  ops[#ops + 1] = { link = { tail, inputs[1] } }
  inputs[1] = head
  return { ops = ops, inputs = inputs, outputs = outputs, buffer = buffer }
end

-- Starts placing `net` in a region it reserves on the hidden surface: plans it; no entity is
-- created yet. Returns a job for builder.advance (plain data and LuaEntity references, so it can
-- be kept in `storage` across ticks and saves), or nil and the error. Placement is all or
-- nothing: builder.advance (on a failure) or builder.abort removes everything it created.
---@param net mb.Network network.build result
---@param tier string "basic" | "fast" | "express" | "turbo"
---@param force? ForceID owner of the hidden entities (default "player")
---@return table? job { placed, ops, i, inputs, outputs, buffer }
---@return string? err
function builder.start(net, tier, force)
  local w, h = builder.size(net)
  local placed = {
    origin = surface.reserve(w, h),
    size = { w = w, h = h },
    tier = tier,
    force = force or "player",
    inputs = {},
    outputs = {},
    entities = {},
    dead_ends = {}, -- unit numbers of splitters with a closed dead-end output
  }
  local ok, p = pcall(plan, net, tier, placed.origin)
  if not ok then
    surface.release(placed.origin)
    return nil, tostring(p)
  end
  return { placed = placed, ops = p.ops, i = 1, inputs = p.inputs, outputs = p.outputs, buffer = p.buffer }
end

-- Runs the operations of `job` from job.i on, until about `budget` units are spent.
local function run(job, budget)
  local placed = job.placed
  local s = surface.get()
  local ops, cost = job.ops, builder.COST
  local used = 0
  while job.i <= #ops and used < budget do
    local op = ops[job.i]
    if op.link then
      placed.entities[op.link[1]].connect_linked_belts(placed.entities[op.link[2]])
      used = used + cost.link
    else
      ---@diagnostic disable-next-line
      if builder.fail_after and #placed.entities + 1 >= builder.fail_after then
        error("builder: test hook failure at entity " .. (#placed.entities + 1))
      end
      local e = s.create_entity({
        name = op.name, position = op.position, direction = op.direction, type = op.type,
        force = placed.force, create_build_effect_smoke = false,
      })
      if not e then
        error("builder: could not create " .. op.name .. " at " .. serpent.line(op.position))
      end
      placed.entities[#placed.entities + 1] = e
      -- nothing on the hidden surface (a creature hatched from an egg that spoiled on a belt, an
      -- explosion) can damage the network
      e.destructible = false
      if op.prio then
        e.splitter_output_priority = op.prio
      end
      if op.filter then
        e.splitter_filter = { name = NEVER }
      end
      if op.dead then
        placed.dead_ends[e.unit_number] = true
      end
      used = used + cost.create
    end
    job.i = job.i + 1
  end
  return used
end

-- Removes what a started placement created and frees its region.
---@param job table builder.start result
function builder.abort(job)
  local placed = job.placed
  for _, e in ipairs(placed.entities) do
    if e.valid then
      e.destroy()
    end
  end
  placed.entities = {}
  if placed.origin then
    surface.release(placed.origin)
    placed.origin = nil
  end
  job.ops = {}
end

-- Places more of `job`, spending about `budget` work units (builder.COST) at most. Returns true
-- when the network is complete (job.placed is then a working Placed), false when there is more
-- to do, or nil and the error when placement failed (everything it created is removed and its
-- region freed); and the units spent.
---@param job table builder.start result
---@param budget number
---@return boolean? done
---@return number used
---@return string? err
function builder.advance(job, budget)
  local ok, used = pcall(run, job, budget)
  if not ok then
    builder.abort(job)
    return nil, 0, tostring(used)
  end
  if job.i <= #job.ops then
    return false, used
  end
  local placed = job.placed
  for i, k in pairs(job.inputs) do
    placed.inputs[i] = placed.entities[k]
  end
  for j, k in pairs(job.outputs) do
    placed.outputs[j] = placed.entities[k]
  end
  placed.buffer = placed.entities[job.buffer]
  job.ops = {}
  return true, used
end

-- Places `net` in a region it reserves on the hidden surface, at once. All or nothing: on any
-- failure every entity it created is destroyed, the region is released, and it returns nil and
-- the error.
---@param net mb.Network network.build result
---@param tier string "basic" | "fast" | "express" | "turbo"
---@param force? ForceID owner of the hidden entities (default "player")
---@return table? placed { origin, size, tier, force, inputs, outputs, entities, buffer, dead_ends }
---@return string? err
function builder.place(net, tier, force)
  local job, err = builder.start(net, tier, force)
  if not job then
    return nil, err
  end
  local done, _, e = builder.advance(job, math.huge)
  if not done then
    return nil, e
  end
  return job.placed
end

-- The items on (and in) every entity of `placed`: one entry per item and quality, sorted by name
-- then quality: { {name = "iron-plate", quality = "normal", count = 10}, ... }. A count summary
-- (rebuild carries the stacks themselves). `mb-hidden-never` is left out: it can only exist by
-- cheating, and dropping it on destroy or rebuild clears the lane it jams.
---@param placed table
---@return {name: string, quality: string, count: integer}[] items
function builder.contents(placed)
  local by_key, items = {}, {}
  local function add(stack)
    if stack.name == NEVER then
      return
    end
    local quality = stack.quality or "normal"
    local key = stack.name .. "/" .. quality
    local entry = by_key[key]
    if not entry then
      entry = { name = stack.name, quality = quality, count = 0 }
      by_key[key] = entry
      items[#items + 1] = entry
    end
    entry.count = entry.count + stack.count
  end
  for _, e in ipairs(placed.entities) do
    if e.valid then
      if e.type == "container" then
        for _, stack in ipairs(e.get_inventory(defines.inventory.chest).get_contents()) do
          add(stack)
        end
      else
        for i = 1, e.get_max_transport_line_index() do
          for _, stack in ipairs(e.get_transport_line(i).get_contents()) do
            add(stack)
          end
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.quality < b.quality
  end)
  return items
end

-- Destroys every entity of `placed`, releases its region and returns the items that were on
-- them (builder.contents). An empty network gives an empty list.
---@param placed table
---@return {name: string, quality: string, count: integer}[] items
function builder.destroy(placed)
  local items = builder.contents(placed)
  for _, e in ipairs(placed.entities) do
    if e.valid then
      e.destroy()
    end
  end
  if placed.origin then
    surface.release(placed.origin)
    placed.origin = nil
  end
  placed.entities, placed.inputs, placed.outputs, placed.buffer = {}, {}, {}, nil
  return items
end

-- Every item stack on (and in) the entities of `placed`, as LuaItemStack handles into those
-- entities (not copies): belt items via get_detailed_contents, the buffer slot by slot. Items
-- of `mb-hidden-never` are left out.
local function stacks_of(placed)
  local list = {}
  for _, e in ipairs(placed.entities) do
    if e.valid then
      if e.type == "container" then
        local inv = e.get_inventory(defines.inventory.chest)
        for i = 1, #inv do
          local st = inv[i]
          if st.valid_for_read and st.name ~= NEVER then
            list[#list + 1] = st
          end
        end
      else
        for i = 1, e.get_max_transport_line_index() do
          for _, d in ipairs(e.get_transport_line(i).get_detailed_contents()) do
            if d.stack.name ~= NEVER then
              list[#list + 1] = d.stack
            end
          end
        end
      end
    end
  end
  return list
end

-- Puts copies of `sources` (LuaItemStacks of the old network, left untouched) into `placed`,
-- keeping item data and spoilage:
-- - onto the hidden belts, one item at a time (insert_at with the stack itself and
--   belt_stack_size 1, so each belt item keeps its own data and spoil fraction), wherever there
--   is room. A stack that a free belt position refuses goes to the buffer. So does a stack of
--   several items with per-item state (ammo, tools such as repair packs and science packs,
--   damaged items): copying one of them would copy the top item's partial ammo, durability or
--   health onto every copy.
-- - the rest into the buffer chest, slot by slot. A whole stack is inserted as itself; the
--   rest of a partly moved stack is a full copy of the stack (set_stack into a one-slot script
--   inventory, which keeps every field) with its count lowered. Inserting merges stacks like
--   any chest: merged spoilables average their spoil fraction, so the total spoilage is kept.
--   The chest is then sorted and shrunk to the slots it uses.
-- Returns false if more than builder.max_buffer_slots slots would be needed.
-- A stack that must not be split onto belts one item at a time (see carry_in).
local SPLIT_UNSAFE = { ammo = true, tool = true, ["repair-tool"] = true }
local function keep_whole(st)
  return st.count > 1 and (SPLIT_UNSAFE[st.type] or st.health < 1)
end

---@return boolean
local function carry_into(placed, sources, tmp)
  local left = {} -- items of sources[i] not yet carried
  for i, st in ipairs(sources) do
    left[i] = st.count
  end
  local k = 1
  local function current()
    while k <= #sources and (left[k] == 0 or keep_whole(sources[k])) do
      k = k + 1
    end
    return k <= #sources and sources[k] or nil
  end
  local st = current()
  for _, e in ipairs(placed.entities) do
    if not st then
      break
    end
    -- not onto a dead-end splitter: an item put on its closed output line would stay there
    if e.type ~= "container" and e.type ~= "loader-1x1" and not placed.dead_ends[e.unit_number] then
      for i = 1, e.get_max_transport_line_index() do
        local line = e.get_transport_line(i)
        local pos = 0.0
        while st and pos < line.line_length do
          if line.can_insert_at(pos) then
            local before = line.get_item_count()
            local moved = line.insert_at(pos, st, 1) and line.get_item_count() - before or 0
            if moved > 0 then
              if moved > left[k] then
                error("builder: a belt took " .. moved .. " items of a stack with " .. left[k] .. " left")
              end
              left[k] = left[k] - moved
            else
              k = k + 1 -- refused on a free position: this stack goes to the buffer
            end
            st = current()
          end
          pos = pos + 0.25
        end
      end
    end
  end
  local rest = 0
  for i = 1, #sources do
    if left[i] > 0 then
      rest = rest + 1
    end
  end
  if rest == 0 then
    return true
  end
  local buffer = placed.buffer
  -- one slot per remaining stack after what the buffer already holds is always enough, but that
  -- counts unmerged stacks (one per belt item): the size is capped at builder.max_buffer_slots
  -- and the inserts merge as they go, so it refuses only when the merged items do not fit
  local inv = buffer.get_inventory(defines.inventory.chest)
  inv.sort_and_merge()
  local held = #inv - inv.count_empty_stacks()
  buffer.set_inventory_size_override(defines.inventory.chest, math.max(1, math.min(held + rest, builder.max_buffer_slots)))
  inv = buffer.get_inventory(defines.inventory.chest)
  for i, src in ipairs(sources) do
    local n = left[i] --[[@as integer]]
    if n > 0 then
      local stack = src
      if n < src.count then
        tmp[1].set_stack(src)
        tmp[1].count = n
        stack = tmp[1]
      end
      local moved = inv.insert(stack)
      if moved ~= n then
        local rest_n = (n - moved) --[[@as uint32]]
        inv.sort_and_merge()
        if moved > 0 then
          tmp[1].set_stack(src)
          tmp[1].count = rest_n
          stack = tmp[1]
        end
        if inv.insert(stack) ~= rest_n then
          return false -- the caller destroys the new network: nothing was taken from the old one
        end
      end
      tmp[1].clear()
    end
  end
  inv.sort_and_merge()
  local used = #inv - inv.count_empty_stacks()
  buffer.set_inventory_size_override(defines.inventory.chest, math.max(1, used))
  return true
end

---@return boolean
local function carry_in(placed, sources)
  local tmp = game.create_inventory(1)
  local ok, fits = pcall(carry_into, placed, sources, tmp)
  tmp.destroy()
  if not ok then
    error(fits)
  end
  return fits == true
end

-- Replaces `old` by `net`: places the new network, copies every item stack of the old one into it
-- (carry_in, item data and spoilage kept) and then destroys the old one. All or nothing: if the
-- new network cannot be placed, cannot hold the items, or carrying them in raises an error, the
-- new one is destroyed, `old` is left as it was, and it returns nil and the error. The caller
-- relinks the visible edges to the new inputs and outputs.
-- `extra` (optional) lists more old networks (balancers merged into this one) whose items are
-- carried in and which are destroyed too, all or nothing with `old`.
---@param old table Placed
---@param net mb.Network
---@param tier string
---@param force? ForceID
---@param extra? table[] more Placed
---@return table? placed
---@return string? err
function builder.rebuild(old, net, tier, force, extra)
  local new, err = builder.place(net, tier, force)
  if not new then
    return nil, err
  end
  local olds = { old }
  for _, p in ipairs(extra or {}) do
    olds[#olds + 1] = p
  end
  local carried, result = pcall(function()
    local sources = {}
    for _, p in ipairs(olds) do
      for _, st in ipairs(stacks_of(p)) do
        sources[#sources + 1] = st
      end
    end
    return carry_in(new, sources)
  end)
  if not carried or not result then
    builder.destroy(new)
    if carried then
      return nil, "too-many-items"
    end
    return nil, tostring(result)
  end
  for _, p in ipairs(olds) do
    builder.destroy(p)
  end
  return new
end

-- Moves every item stack of `inv` (a script inventory, emptied) into `placed`'s buffer chest,
-- which drains into the network. Returns false and moves nothing if the buffer would need more
-- than builder.max_buffer_slots slots.
---@param placed table
---@param inv LuaInventory
---@return boolean
function builder.stash(placed, inv)
  local buffer = placed.buffer
  if not (buffer and buffer.valid) then
    return false
  end
  local binv = buffer.get_inventory(defines.inventory.chest)
  binv.sort_and_merge()
  local held = #binv - binv.count_empty_stacks()
  local need = #inv - inv.count_empty_stacks()
  if need == 0 then
    return true
  end
  if held + need > builder.max_buffer_slots then
    return false
  end
  buffer.set_inventory_size_override(defines.inventory.chest, held + need)
  binv = buffer.get_inventory(defines.inventory.chest)
  for i = 1, #inv do
    local st = inv[i] --[[@as LuaItemStack]]
    if st.valid_for_read and st.name ~= NEVER then
      local n = binv.insert(st)
      if n < st.count then
        -- cannot happen with one slot per source stack; never drop silently
        st.count = (st.count - n) --[[@as uint32]]
        buffer.surface.spill_item_stack({ position = buffer.position, stack = st, enable_looted = true, drop_full_stack = true })
      end
    end
    st.clear()
  end
  binv.sort_and_merge()
  buffer.set_inventory_size_override(defines.inventory.chest, math.max(1, #binv - binv.count_empty_stacks()))
  return true
end

-- Disconnects the network inputs and outputs of `placed` from whatever they are linked to (the
-- visible ports, another group's network on a shared tile), so no item enters or leaves it any
-- more: its items only move inside it until builder.drain or builder.take moves them out.
---@param placed table
function builder.seal(placed)
  for _, list in ipairs({ placed.inputs, placed.outputs }) do
    for _, e in pairs(list) do
      if e.valid and e.linked_belt_neighbour then
        e.disconnect_linked_belts()
      end
    end
  end
end

-- One item of `src` onto a free belt position of `new` from its fill cursor: true if it moved,
-- false if no belt takes it (the cursor has passed every belt, or a free position refused it).
local function onto_belts(new, src)
  local f = new.fill
  if not f then
    f = { k = 1, li = 1, pos = 0.0 }
    new.fill = f
  end
  local ents = new.entities
  while f.k <= #ents do
    local e = ents[f.k]
    if e.valid and e.type ~= "container" and e.type ~= "loader-1x1" and not new.dead_ends[e.unit_number]
      and f.li <= e.get_max_transport_line_index() then
      local line = e.get_transport_line(f.li)
      local len = line.line_length
      while f.pos < len do
        if line.can_insert_at(f.pos) then
          if not line.insert_at(f.pos, src, 1) then
            return false -- refused on a free position: this stack goes to the buffer
          end
          local n = src.count
          if n > 1 then
            src.count = n - 1
          else
            src.clear()
          end
          return true
        end
        f.pos = f.pos + 0.25
      end
      f.li, f.pos = f.li + 1, 0.0
    else
      f.k, f.li, f.pos = f.k + 1, 1, 0.0
    end
  end
  return false
end

-- Moves the stack `src` (a handle into a sealed network: a belt item or a chest slot) into the
-- network `new`, keeping item data and spoilage, and lowers or clears `src` by what moved:
-- - onto the belts of `new`, one item at a time (insert_at with the stack itself and
--   belt_stack_size 1, so each belt item keeps its own data and spoil fraction), at the first
--   free position from the cursor new.fill (kept across calls and ticks), skipping dead-end
--   splitters (an item on a closed output line would stay there). A stack that a free position
--   refuses goes to the buffer, and so does a stack of several items with per-item state (ammo,
--   tools, damaged items: copying one would copy the top item's state onto every copy);
-- - once the cursor has passed every belt, into the buffer chest: a whole stack as itself, the
--   rest of a partly moved stack as a full copy (set_stack into the one-slot `tmp`) with its
--   count lowered. Inserting merges stacks like any chest (merged spoilables average their
--   spoil fraction, so the total spoilage is kept); the chest grows as needed, up to
--   builder.max_buffer_slots slots.
-- Returns the number of items moved (0: `new` cannot take any of it now).
---@param new table Placed
---@param src LuaItemStack
---@param tmp LuaInventory
---@return integer
local function put_into(new, src, tmp)
  if not keep_whole(src) and onto_belts(new, src) then
    return 1
  end
  local buffer = new.buffer
  if not (buffer and buffer.valid) then
    return 0
  end
  local inv = buffer.get_inventory(defines.inventory.chest) --[[@as LuaInventory]]
  local want = src.count
  local left = want
  local function try()
    local stack = src
    if left < want then
      tmp[1].set_stack(src)
      tmp[1].count = left
      stack = tmp[1]
    end
    left = left - inv.insert(stack)
    tmp[1].clear()
  end
  try()
  if left > 0 then
    inv.sort_and_merge()
    try()
  end
  while left > 0 do
    local size = #inv
    if size >= builder.max_buffer_slots then
      break
    end
    buffer.set_inventory_size_override(defines.inventory.chest, math.min(builder.max_buffer_slots, math.max(size * 2, size + 16)))
    inv = buffer.get_inventory(defines.inventory.chest) --[[@as LuaInventory]]
    try()
  end
  local moved = want - left
  if left == 0 then
    src.clear()
  elseif moved > 0 then
    src.count = left
  end
  return moved
end

-- Moves every item off entity `e` with `put` (a belt's lines last item first, so the handles of
-- the items before it stay valid; a chest's slots last first), within about `budget` units.
-- Returns true when `e` is empty, false when the budget ran out first (a chest is emptied over
-- several calls), or nil when `put` could not take an item; and the units spent.
---@param e LuaEntity
---@param put fun(st: LuaItemStack): integer
---@param budget number
---@return boolean?, number
local function empty_entity(e, put, budget)
  local cost = builder.COST.item
  ---@type number
  local used = 0
  if e.type == "container" then
    local inv = e.get_inventory(defines.inventory.chest) --[[@as LuaInventory]]
    for i = #inv, 1, -1 do
      if used >= budget then
        return false, used
      end
      local st = inv[i] --[[@as LuaItemStack]]
      if st.valid_for_read and st.name ~= NEVER then
        while st.valid and st.valid_for_read do
          local n = put(st)
          if n == 0 then
            return nil, used
          end
          used = used + cost
        end
      end
    end
    return true, used
  end
  for li = 1, e.get_max_transport_line_index() do
    local d = e.get_transport_line(li --[[@as defines.transport_line]]).get_detailed_contents()
    for i = #d, 1, -1 do
      local st = d[i].stack
      if st.name ~= NEVER then
        while st.valid and st.valid_for_read do
          local n = put(st)
          if n == 0 then
            return nil, used
          end
          used = used + cost
        end
      end
    end
  end
  return true, used
end

-- Empties the sealed network `old` (builder.seal) into `put` entity by entity, destroying each
-- entity once it is empty, within about `budget` units (builder.COST); old.drain_k is the cursor,
-- kept across calls and ticks. An item can only move from an entity not reached yet to another
-- one not reached yet (the reached ones are gone), so every item is moved exactly once, whatever
-- happens between ticks. Items of `mb-hidden-never` are dropped with their entity. When every
-- entity is gone, the region is freed. Returns "done", "more" (budget spent) or "stuck" (`put`
-- could not take an item: nothing is lost, the rest stays in `old`), and the units spent.
---@param old table Placed
---@param put fun(st: LuaItemStack): integer
---@param budget number
---@return string, number
local function drain_into(old, put, budget)
  local destroy = builder.COST.destroy
  local ents = old.entities
  ---@type number
  local used = 0
  old.drain_k = old.drain_k or 1
  while old.drain_k <= #ents do
    if used >= budget then
      return "more", used
    end
    local e = ents[old.drain_k]
    if e.valid then
      local ok, u = empty_entity(e, put, budget - used)
      used = used + u
      if ok == nil then
        return "stuck", used
      elseif ok == false then
        return "more", used
      end
      e.destroy()
      used = used + destroy
    end
    old.drain_k = old.drain_k + 1
  end
  builder.destroy(old)
  return "done", used
end

-- Moves the items of the sealed network `old` into the working network `new` (put_into: onto its
-- belts, else into its buffer chest) and removes `old`, over as many calls as the budget needs
-- (see drain_into). Returns "done", "more" or "stuck" (the buffer of `new` is full at
-- builder.max_buffer_slots slots: the rest stays in `old`, safe), and the units spent.
---@param new table Placed
---@param old table Placed
---@param budget number
---@return string, number
function builder.drain(new, old, budget)
  local tmp = game.create_inventory(1)
  local ok, status, used = pcall(drain_into, old, function(st)
    return put_into(new, st, tmp)
  end, budget)
  tmp.destroy()
  if not ok then
    error(status)
  end
  return status, used
end

-- After a drain into `placed`: merges its buffer's stacks and shrinks the chest to the slots it
-- uses, and rewinds the fill cursor for the next drain.
---@param placed table
function builder.settle(placed)
  placed.fill = nil
  local buffer = placed.buffer
  if buffer and buffer.valid and buffer.get_inventory_size_override(defines.inventory.chest) then
    local inv = buffer.get_inventory(defines.inventory.chest) --[[@as LuaInventory]]
    inv.sort_and_merge()
    buffer.set_inventory_size_override(defines.inventory.chest, math.max(1, #inv - inv.count_empty_stacks()))
  end
end

-- Replaces `old` by `net` with the staged primitives, at once: places the new network, seals the
-- old ones and drains them into it (builder.drain). The placement is all or nothing (nil and the
-- error, `old` untouched). A drain that gets stuck (the new buffer full) leaves the rest of the
-- items in the old networks and returns the new network, the error "too-many-items" and the old
-- networks still holding items: nothing is lost. The live balancer (scripts/balancer.lua) runs
-- the same steps spread over ticks; tests use this to check the drain keeps item data.
---@param old table Placed
---@param net mb.Network
---@param tier string
---@param force? ForceID
---@param extra? table[]
---@return table? placed
---@return string? err
---@return table[]? left
function builder.rebuild_staged(old, net, tier, force, extra)
  local new, err = builder.place(net, tier, force)
  if not new then
    return nil, err
  end
  local olds = { old }
  for _, p in ipairs(extra or {}) do
    olds[#olds + 1] = p
  end
  local left = {}
  for _, p in ipairs(olds) do
    builder.seal(p)
    if builder.drain(new, p, math.huge) ~= "done" then
      left[#left + 1] = p
    end
  end
  builder.settle(new)
  if #left > 0 then
    return new, "too-many-items", left
  end
  return new
end

-- Takes every item out of `placed` into script inventories of at most builder.max_take_slots
-- slots each (item data and spoilage kept), destroying its entities as they are emptied (see
-- drain_into). The items are inserted one source stack at a time, so they merge as they go (a
-- full network of tens of thousands of single plates fits in a few hundred slots); an inventory
-- that is full even merged is closed and a new one opened. Never sized by item count. With a
-- `budget` (work units) it stops when the budget is spent and `placed` keeps the rest; without,
-- it takes everything. Returns the inventories, the number of items, whether `placed` is now
-- gone (its region freed), and the units spent. The caller empties and destroys every inventory
-- (a balancer removed with items inside: scripts/balancer.lua gives them to whoever removed it,
-- or spills them).
---@param placed table
---@param budget number?
---@return LuaInventory[], integer, boolean?, number?
function builder.take(placed, budget)
  local cap = math.max(1, math.min(builder.max_take_slots, 65535))
  local size = math.min(cap, 1024)
  local invs = {}
  local inv = game.create_inventory(size)
  invs[1] = inv
  local tmp = game.create_inventory(1)
  local n = 0
  local function put(st)
    local count = st.count
    local moved = inv.insert(st)
    if moved < count then
      inv.sort_and_merge()
      -- the rest as a full copy of the stack (set_stack keeps every field), its count lowered
      tmp[1].set_stack(st)
      tmp[1].count = (count - moved) --[[@as uint32]]
      local more = inv.insert(tmp[1])
      if more < tmp[1].count then
        tmp[1].count = tmp[1].count - more
        inv = game.create_inventory(size)
        invs[#invs + 1] = inv
        if inv.insert(tmp[1]) < tmp[1].count then
          error("builder.take: a stack does not fit in an empty inventory")
        end
      end
      tmp[1].clear()
    end
    st.clear()
    n = n + count
    return count
  end
  local ok, status, used = pcall(drain_into, placed, put, budget or math.huge)
  tmp.destroy()
  if not ok then
    error(status)
  end
  for _, v in ipairs(invs) do
    v.sort_and_merge()
  end
  return invs, n, status == "done", used
end

-- Destroys `placed` and spills every item it held (merged into whole stacks first, item data and
-- spoilage kept) on the ground around `position` of `surf`, marked to be looted. Returns the
-- number of items spilled.
---@param placed table
---@param surf LuaSurface
---@param position MapPosition
---@return integer
function builder.spill(placed, surf, position)
  local invs, n = builder.take(placed)
  for _, inv in ipairs(invs) do
    for i = 1, #inv do
      local st = inv[i] --[[@as LuaItemStack]]
      if st.valid_for_read then
        surf.spill_item_stack({ position = position, stack = st, enable_looted = true, allow_belts = false, drop_full_stack = true })
      end
    end
    inv.destroy()
  end
  return n
end

-- Shrinks `placed`'s buffer chest back to its prototype size once it is empty (after a big
-- shrink it can have up to builder.max_buffer_slots slots). No per-tick work: call it from an
-- event that touches the group (Plan 2 Task 4). Returns true if it shrank the chest.
---@param placed table
---@return boolean
function builder.compact(placed)
  local buffer = placed.buffer
  if buffer and buffer.valid and buffer.get_item_count() == 0
    and buffer.get_inventory_size_override(defines.inventory.chest) then
    buffer.set_inventory_size_override(defines.inventory.chest, nil)
    return true
  end
  return false
end

-- Hidden tier entities whose speed differs from their tier's belt (a mod changed a belt speed
-- after modular-balancer's data-final-fixes read it). Returns a list of messages; control.lua
-- logs them on init and configuration change.
---@return string[]
function builder.speed_mismatches()
  local out = {}
  for tier, belt in pairs(TIER_BELTS) do
    local bp = prototypes.entity[belt]
    ---@diagnostic disable-next-line: unnecessary-if
    if bp and prototypes.entity["mb-hidden-linked-belt-" .. tier] then
      for _, kind in ipairs({ "splitter", "linked-belt", "lane-splitter", "loader" }) do
        local p = prototypes.entity["mb-hidden-" .. kind .. "-" .. tier]
        if not p or p.belt_speed ~= bp.belt_speed then
          out[#out + 1] = string.format("mb-hidden-%s-%s speed %s, %s speed %s", kind, tier,
            tostring(p and p.belt_speed), belt, tostring(bp.belt_speed))
        end
      end
    end
  end
  return out
end

return builder
