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
-- So input 1 and the buffer share one network input: while the buffer holds items, input 1 is
-- drawn at up to half a belt; once it is empty, input 1 runs at full speed and the network is
-- unchanged. (A separate network input for the buffer would sit empty in the steady state, and
-- an empty input breaks equal input draw in a balancer.)
local surface = require("scripts.surface")

local builder = {}

local CELL_W, CELL_H = 4, 3
local BUFFER_W = 5
local EAST = defines.direction.east
local MAX_BUFFER_SLOTS = 65535 -- uint16, set_inventory_size_override

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

-- Creates every entity of `net` into `placed` (raises on any failure).
local function build(net, tier, placed, s)
  local cols = grid(net)
  local origin = placed.origin
  local lb_name = "mb-hidden-linked-belt-" .. tier

  local function create(t)
    ---@diagnostic disable-next-line
    if builder.fail_after and #placed.entities + 1 >= builder.fail_after then
      error("builder: test hook failure at entity " .. (#placed.entities + 1))
    end
    t.force = placed.force
    t.create_build_effect_smoke = false
    local e = s.create_entity(t)
    if not e then
      error("builder: could not create " .. t.name .. " at " .. serpent.line(t.position))
    end
    placed.entities[#placed.entities + 1] = e
    return e
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
  local in_tile = { splitter = {}, priority = {}, lane_splitter = {} }
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
    local e = create({ name = "mb-hidden-splitter-" .. tier, position = { x + 1.5, y + 1 }, direction = EAST })
    if kind == "priority" then
      e.splitter_output_priority = "left"
    else
      local o = outs[id] or {}
      if o[1] ~= o[2] then
        e.splitter_output_priority = o[1] and "right" or "left"
        e.splitter_filter = { name = "mb-hidden-never" }
        placed.dead_ends[e.unit_number] = true
      end
    end
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

  for _, ed in ipairs(net.edges) do
    local from, to = ed.from, ed.to
    local tail, head -- input-type on the source side, output-type on the target side
    if from.kind == "in" and to.kind == "out" then
      local x, y = cell()
      head = linked_belt({ x + 0.5, y + 0.5 }, "output")
      tail = linked_belt({ x + 1.5, y + 0.5 }, "input")
    else
      if from.kind ~= "in" then
        tail = linked_belt(out_tile[from.kind][from.id][from.port], "input")
      end
      if to.kind ~= "out" then
        head = linked_belt(in_tile[to.kind][to.id][to.port], "output")
      end
      if tail and head then
        tail.connect_linked_belts(head)
      end
    end
    if from.kind == "in" then
      placed.inputs[from.id] = head
    end
    if to.kind == "out" then
      placed.outputs[to.id] = tail
    end
  end

  -- The buffer strip, merged into input 1.
  local bx, by = origin.x + cols * CELL_W, origin.y
  placed.buffer = create({ name = "mb-hidden-buffer", position = { bx + 0.5, by + 1.5 } })
  local head = linked_belt({ bx + 1.5, by + 0.5 }, "output")
  create({ name = "mb-hidden-loader-" .. tier, position = { bx + 1.5, by + 1.5 }, direction = EAST, type = "output" })
  local merge = create({ name = "mb-hidden-splitter-" .. tier, position = { bx + 2.5, by + 1 }, direction = EAST })
  merge.splitter_output_priority = "right"
  merge.splitter_filter = { name = "mb-hidden-never" }
  placed.dead_ends[merge.unit_number] = true
  local tail = linked_belt({ bx + 3.5, by + 0.5 }, "input")
  tail.connect_linked_belts(placed.inputs[1])
  placed.inputs[1] = head
end

-- Places `net` in a region it reserves on the hidden surface. All or nothing: on any failure
-- every entity it created is destroyed, the region is released, and it returns nil and the
-- error.
---@param net mb.Network network.build result
---@param tier string "basic" | "fast" | "express" | "turbo"
---@param force? ForceID owner of the hidden entities (default "player")
---@return table? placed { origin, size, tier, force, inputs, outputs, entities, buffer, dead_ends }
---@return string? err
function builder.place(net, tier, force)
  local s = surface.get()
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
  local ok, err = pcall(build, net, tier, placed, s)
  if not ok then
    for _, e in ipairs(placed.entities) do
      if e.valid then
        e.destroy()
      end
    end
    surface.release(placed.origin)
    return nil, tostring(err)
  end
  return placed
end

-- The items on (and in) every entity of `placed`: one entry per item and quality, sorted by name
-- then quality: { {name = "iron-plate", quality = "normal", count = 10}, ... }.
---@param placed table
---@return {name: string, quality: string, count: integer}[] items
function builder.contents(placed)
  local by_key, items = {}, {}
  local function add(stack)
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

-- Puts `items` into `placed`: first onto its hidden belts wherever there is room, then the rest
-- into its buffer chest, grown to fit. Returns false if the buffer cannot hold the rest (more
-- than MAX_BUFFER_SLOTS stacks); the caller then throws `placed` away.
local function carry_in(placed, items)
  local pending = {}
  for _, it in ipairs(items) do
    pending[#pending + 1] = { name = it.name, quality = it.quality, count = it.count }
  end
  local k = 1
  for _, e in ipairs(placed.entities) do
    if k > #pending then
      break
    end
    -- not onto a dead-end splitter: an item put on its closed output line would stay there
    if e.type ~= "container" and e.type ~= "loader-1x1" and not placed.dead_ends[e.unit_number] then
      for i = 1, e.get_max_transport_line_index() do
        local line = e.get_transport_line(i)
        local pos = 0.0
        while pos < line.line_length and k <= #pending do
          local it = pending[k]
          if line.insert_at(pos, { name = it.name, quality = it.quality, count = 1 }) then
            it.count = it.count - 1
            if it.count == 0 then
              k = k + 1
            end
          end
          pos = pos + 0.25
        end
      end
    end
  end
  if k > #pending then
    return true
  end
  local slots = 0
  for j = k, #pending do
    local it = pending[j] ---@type {name: string, quality: string, count: integer}
    local proto = prototypes.item[it.name] ---@type LuaItemPrototype
    slots = slots + math.ceil(it.count / proto.stack_size)
  end
  if slots > MAX_BUFFER_SLOTS then
    return false
  end
  -- the new network's buffer is empty, so it needs exactly `slots` slots
  local buffer = placed.buffer
  buffer.set_inventory_size_override(defines.inventory.chest, math.max(1, slots))
  local inv = buffer.get_inventory(defines.inventory.chest)
  for j = k, #pending do
    local it = pending[j] ---@type {name: string, quality: string, count: integer}
    local n = inv.insert({ name = it.name, quality = it.quality, count = it.count })
    if n ~= it.count then
      return false
    end
  end
  return true
end

-- Replaces `old` by `net`: places the new network, copies every item of the old one into it
-- (carry_in) and then destroys the old one. All or nothing: if the new network cannot be placed
-- or cannot hold the items, the new one is destroyed, `old` is left as it was, and it returns
-- nil and the error. The caller relinks the visible edges to the new inputs and outputs.
---@param old table Placed
---@param net mb.Network
---@param tier string
---@param force? ForceID
---@return table? placed
---@return string? err
function builder.rebuild(old, net, tier, force)
  local new, err = builder.place(net, tier, force)
  if not new then
    return nil, err
  end
  if not carry_in(new, builder.contents(old)) then
    builder.destroy(new)
    return nil, "too-many-items"
  end
  builder.destroy(old)
  return new
end

return builder
