-- Places a generated network (scripts/network.lua) on the hidden surface and removes it again.
--
-- Every node gets a cell on a grid inside the region reserved at `origin`. A cell is CELL_W x
-- CELL_H tiles, all nodes facing east:
--   splitter       x0: its two input tiles, x0 + 1: the splitter, x0 + 2: its two output
--                  tiles (port 1 on row y0, port 2 on row y0 + 1)
--   lane splitter  x0: input tile, x0 + 1: the lane splitter, x0 + 2: output tile (row y0)
--   pass-through   an edge from a network input straight to an output (1:1): x0 and x0 + 1
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
-- empty too: that output is a dead end and holds a few items on the splitter (network.lua),
-- which destroy() returns with everything else.
local surface = require("scripts.surface")

local builder = {}

local CELL_W, CELL_H = 4, 3
local EAST = defines.direction.east

---@param net table
---@return integer cells, integer cols, integer rows
local function grid(net)
  local direct = 0
  for _, ed in ipairs(net.edges) do
    if ed.from.kind == "in" and ed.to.kind == "out" then
      direct = direct + 1
    end
  end
  local cells = #net.splitters + #(net.lane_splitters or {}) + direct
  local cols = math.max(1, math.ceil(math.sqrt(cells)))
  return cells, cols, math.max(1, math.ceil(cells / cols))
end

-- Size in tiles of the rectangle `place` needs for `net` (pass it to surface.reserve).
---@param net table
---@return integer w, integer h
function builder.size(net)
  local _, cols, rows = grid(net)
  return cols * CELL_W, rows * CELL_H
end

---@param net table network.build result
---@param tier string "basic" | "fast" | "express" | "turbo"
---@param origin {x: number, y: number} top-left tile corner of a region from surface.reserve
---@param force? ForceID owner of the hidden entities (default "player")
---@return table placed { inputs = {LuaEntity}, outputs = {LuaEntity}, entities = {LuaEntity} }
function builder.place(net, tier, origin, force)
  local s = surface.get()
  local _, cols = grid(net)
  local placed = { inputs = {}, outputs = {}, entities = {} }
  local lb_name = "mb-hidden-linked-belt-" .. tier

  local function create(t)
    t.force = force or "player"
    t.create_build_effect_smoke = false
    local e = s.create_entity(t)
    assert(e, "builder: could not create " .. t.name .. " at " .. serpent.line(t.position))
    placed.entities[#placed.entities + 1] = e
    return e
  end

  -- Top-left tile of each cell, in order: splitters, lane splitters, pass-throughs.
  local next_cell = 0
  local function cell()
    local c = next_cell
    next_cell = next_cell + 1
    return origin.x + (c % cols) * CELL_W, origin.y + math.floor(c / cols) * CELL_H
  end

  -- Tile centre of each node's ports: in_tile[kind][id][port], out_tile[kind][id][port].
  local in_tile, out_tile = { splitter = {}, lane_splitter = {} }, { splitter = {}, lane_splitter = {} }
  for _, sp in ipairs(net.splitters) do
    local x, y = cell()
    create({ name = "mb-hidden-splitter-" .. tier, position = { x + 1.5, y + 1 }, direction = EAST })
    in_tile.splitter[sp.id] = { { x + 0.5, y + 0.5 }, { x + 0.5, y + 1.5 } }
    out_tile.splitter[sp.id] = { { x + 2.5, y + 0.5 }, { x + 2.5, y + 1.5 } }
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
  return placed
end

-- Destroys every entity of `placed` and returns the items that were on them, one entry per item
-- and quality, sorted by name then quality: { {name = "iron-plate", quality = "normal",
-- count = 10}, ... } (an empty list for an empty network).
---@param placed table
---@return {name: string, quality: string, count: integer}[] items
function builder.destroy(placed)
  local by_key = {}
  local items = {}
  for _, e in ipairs(placed.entities) do
    if e.valid then
      for i = 1, e.get_max_transport_line_index() do
        for _, stack in ipairs(e.get_transport_line(i).get_contents()) do
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
      end
      e.destroy()
    end
  end
  table.sort(items, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.quality < b.quality
  end)
  placed.entities, placed.inputs, placed.outputs = {}, {}, {}
  return items
end

return builder
