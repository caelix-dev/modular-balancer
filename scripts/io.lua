-- Belts and inserters around a group of blocks (docs/feasibility.md F1, F3, F4): finds a group's
-- inputs and outputs, swaps belt tiles for edges and back, and places the linked belts that sit
-- on a block's own tile. Runs only from scripts/balancer.lua (build, remove and rotate events).
--
-- Ports. For each block and each side d whose neighbour tile T holds no block:
--   edge      a plain transport belt on T pointing straight into the block (input) or leaving it
--             straight (output). T is swapped for an edge linked belt mb-edge-in|out-<belt>
--             (same belt, direction and quality, items kept). A curved input tile is refused; a
--             curved output tile is a belt fed from its side turning away, so it is not an
--             output; a straight output tile with a side input is refused (output edges never
--             take side loading). Belts alongside the block (perpendicular) are ignored.
--   shared    the same, with a block (of any group) on the far side of T too: T is the output of
--             one block and the input of the other. T stays a plain belt; the two networks are
--             linked directly (scripts/balancer.lua). Blocks of different forces are refused.
--   tile      T holds another belt-connectable (an underground belt, a splitter, a lane splitter,
--             another mod's linked belt, or a transport belt with no edge prototype) that feeds
--             into the block or takes from it: a linked belt on the block's own tile faces T (the
--             block-tile interface). At most one per block; a second one is refused. An edge
--             candidate with circuit wires or a control behaviour is served the same way, so the
--             player's belt and its wires stay untouched (Ruling 7); with the block's tile
--             already taken it is refused ("wired-belt"), never swapped.
--   inserter  inserters whose pickup position is on the block tile take from it (one output
--             port per block), those whose drop position is on it put into it (one input port).
--             The port is a linked belt on the block tile facing a free side (belt_io.block_port).
--             Both directions on one block are refused, and so is an inserter port on a block
--             that already has a block-tile interface (one belt-connectable per tile).
-- A shared tile links the two networks directly, so it runs at the networks' speed whatever the
-- tier of the belt on it (the belt itself carries nothing).
-- Loaders next to a block are ignored, and so are inserters of other forces. Inserter roles follow pickup_position and drop_position;
-- a script that writes those raises no event, so a role can be stale until the next re-check.
--
-- Items are never dropped: a swap moves every item of the old entity onto the new one (its own
-- line and position if free, else another free position on that line, else force-inserted).
local groups = require("scripts.groups")

local belt_io = {}

local D = defines.direction
---@type table<defines.direction, {[1]: integer, [2]: integer}>
local VEC = { [D.north] = { 0, -1 }, [D.east] = { 1, 0 }, [D.south] = { 0, 1 }, [D.west] = { -1, 0 } }
local OPPOSITE = { [D.north] = D.south, [D.east] = D.west, [D.south] = D.north, [D.west] = D.east }
belt_io.SIDES = { D.north, D.east, D.south, D.west }
belt_io.OPPOSITE = OPPOSITE

-- Belt-connectable entity types, for event filters and searches.
belt_io.BELT_TYPES = { "transport-belt", "underground-belt", "splitter", "lane-splitter", "linked-belt", "loader", "loader-1x1" }
local IS_BELT_TYPE = {}
for _, t in ipairs(belt_io.BELT_TYPES) do
  IS_BELT_TYPE[t] = true
end
belt_io.IS_BELT_TYPE = IS_BELT_TYPE

local EDGE = "mb-edge-"
local HIDDEN = "mb-hidden-"
local HIDDEN_LB = "mb-hidden-linked-belt-"

-- True for the mod's own entities on the player's side (edges, block-tile linked belts).
---@param name string
function belt_io.is_ours(name)
  return name:sub(1, #EDGE) == EDGE or name:sub(1, #HIDDEN) == HIDDEN
end

-- For an edge name: the belt it replaces and its role ("in" | "out"); nil otherwise.
---@param name string
---@return string?, string?
function belt_io.edge_belt(name)
  if name:sub(1, #EDGE) ~= EDGE then
    return nil
  end
  local rest = name:sub(#EDGE + 1)
  if rest:sub(1, 3) == "in-" then
    return rest:sub(4), "in"
  elseif rest:sub(1, 4) == "out-" then
    return rest:sub(5), "out"
  end
  return nil
end

-- The edge prototype name for `belt` and `role`, or nil if there is none (a belt added after
-- this mod's data-final-fixes).
---@param belt string
---@param role string "in" | "out"
---@return string?
function belt_io.edge_name(belt, role)
  local name = EDGE .. role .. "-" .. belt
  ---@diagnostic disable-next-line: unnecessary-if
  if prototypes.entity[name] then
    return name
  end
  return nil
end

local function tile_area(x, y)
  return { { x + 0.1, y + 0.1 }, { x + 0.9, y + 0.9 } }
end

---@param p MapPosition
---@return integer, integer
local function floor_pos(p)
  return math.floor((p.x or p[1]) --[[@as number]]), math.floor((p.y or p[2]) --[[@as number]])
end

-- The belt-connectable entity on tile (x, y) (at most one per tile), or nil.
---@param s LuaSurface
---@return LuaEntity?
local function belt_at(s, x, y)
  return s.find_entities_filtered({ area = tile_area(x, y), type = belt_io.BELT_TYPES, limit = 1 })[1]
end

-- What the belts around tile (x, y) of `s` see there: the belt-connectable's name, direction and
-- linked belt type, or "" for none. scripts/balancer.lua compares it before and after a flush.
---@param s LuaSurface
---@return string
function belt_io.tile_signature(s, x, y)
  local e = belt_at(s, x, y)
  if not e then
    return ""
  end
  return e.name .. "/" .. e.direction .. "/" .. (e.type == "linked-belt" and e.linked_belt_type or "")
end

-- The mod's linked belt on a block tile (block-tile interface or inserter port), or nil.
---@param s LuaSurface
---@return LuaEntity?
function belt_io.block_tile_belt(s, x, y)
  for _, e in ipairs(s.find_entities_filtered({ area = tile_area(x, y), type = "linked-belt" })) do
    if e.name:sub(1, #HIDDEN_LB) == HIDDEN_LB then
      return e
    end
  end
  return nil
end

-- Longest inserter reach of any loaded inserter prototype, in whole tiles (2 in vanilla).
---@type integer?
local reach_cache
function belt_io.reach()
  if not reach_cache then
    local r = 1
    for _, p in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "inserter" } })) do
      for _, v in ipairs({ p.inserter_pickup_position, p.inserter_drop_position }) do
        ---@diagnostic disable-next-line: unnecessary-if
        if v then
          local x, y = v.x or v[1], v.y or v[2]
          r = math.max(r, math.ceil(math.abs(x)), math.ceil(math.abs(y)))
        end
      end
    end
    reach_cache = r
  end
  return reach_cache
end

-- Role of a non-edge belt-connectable `e` on the tile at side `d` of a block: "in" if it feeds
-- the block, "out" if it takes from it, else nil.
---@param e LuaEntity
---@param d defines.direction
---@return string?
local function unswappable_role(e, d)
  local into, away, dir, t = OPPOSITE[d], d, e.direction, e.type
  if t == "underground-belt" then
    if e.belt_to_ground_type == "output" and dir == into then
      return "in"
    elseif e.belt_to_ground_type == "input" and dir == away then
      return "out"
    end
  elseif t == "linked-belt" then
    if e.linked_belt_type == "output" and dir == into then
      return "in"
    elseif e.linked_belt_type == "input" and dir == away then
      return "out"
    end
  elseif t == "splitter" or t == "lane-splitter" or t == "transport-belt" then
    if dir == into then
      return "in"
    elseif dir == away then
      return "out"
    end
  end
  return nil
end

-- True when belt `e` has a circuit wire or a control behaviour that does something (enable /
-- disable by circuit or logistic condition, read contents). A swap would lose them (Ruling 7).
---@param e LuaEntity
local function controlled(e)
  for _, c in pairs(e.get_wire_connectors(false)) do
    if c.connection_count > 0 then
      return true
    end
  end
  local cb = e.get_control_behavior() --[[@as LuaTransportBeltControlBehavior?]]
  return cb ~= nil and (cb.circuit_enable_disable or cb.connect_to_logistic_network or cb.read_contents) == true
end

-- Side inputs of a plain belt that leaves a block, not counting the mod's own block-tile linked
-- belt behind it (an inserter port that will move away once the tile is an edge).
---@param e LuaEntity
local function side_fed(e)
  for _, src in ipairs(e.belt_neighbours.inputs) do
    if src.name:sub(1, #HIDDEN_LB) ~= HIDDEN_LB then
      return true
    end
  end
  return false
end

---@class mb.IoPort
---@field kind string "edge" | "shared" | "tile" | "inserter"
---@field role string "in" | "out"
---@field block integer unit number of the block
---@field bx integer block tile
---@field by integer
---@field side defines.direction? from the block to tile T (edge, shared, tile)
---@field tx integer tile of the port entity: T for edge and shared, the block tile otherwise
---@field ty integer
---@field entity LuaEntity? what the scan found on T (edge, tile)
---@field far integer? the block on the far side of a shared tile
---@field visible LuaEntity? set by scripts/balancer.lua: the linked belt linked to the network

-- Finds the ports of `group` in the world as it is now. Inputs and outputs are in a stable
-- order (blocks by tile row then column, sides north, east, south, west, the inserter port
-- last). `refused` lists { reason, position } for scripts/balancer.lua to show.
---@param group mb.Group
---@return { inputs: mb.IoPort[], outputs: mb.IoPort[], refused: { reason: string, position: MapPosition }[] }
function belt_io.scan(group)
  local si = group.surface_index
  local s = game.get_surface(si) --[[@as LuaSurface]]
  local result = { inputs = {}, outputs = {}, refused = {} }
  local function refuse(reason, x, y)
    result.refused[#result.refused + 1] = { reason = reason, position = { x = x + 0.5, y = y + 0.5 } }
  end
  local function add(port)
    local list = port.role == "in" and result.inputs or result.outputs
    list[#list + 1] = port
  end

  local blocks = {}
  for unit, e in pairs(group.blocks) do
    if e.valid then
      local x, y = floor_pos(e.position)
      blocks[#blocks + 1] = { unit = unit, x = x, y = y }
    end
  end
  table.sort(blocks, function(a, b)
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.x < b.x
  end)

  local reach = belt_io.reach()
  for _, b in ipairs(blocks) do
    ---@type table?
    local tile_port
    for _, d in ipairs(belt_io.SIDES) do
      local v = VEC[d]
      local tx, ty = b.x + v[1], b.y + v[2]
      local e = not groups.block_at(si, tx, ty) and belt_at(s, tx, ty) or nil
      if e then
        local port = { block = b.unit, bx = b.x, by = b.y, side = d, tx = tx, ty = ty, entity = e }
        local role = (e.direction == OPPOSITE[d] and "in") or (e.direction == d and "out") or nil
        local edge_belt = belt_io.edge_belt(e.name)
        if edge_belt then
          -- already an edge: its role follows its direction (a rotated edge is swapped again)
          port.kind, port.role = role and "edge", role
        elseif e.type == "transport-belt" and belt_io.edge_name(e.name, "in") then
          if role == "in" then
            if e.belt_shape ~= "straight" then
              refuse("curved", tx, ty)
            else
              port.kind, port.role = "edge", "in"
            end
          elseif role == "out" and e.belt_shape == "straight" then
            if side_fed(e) then
              refuse("side-loaded", tx, ty)
            else
              port.kind, port.role = "edge", "out"
            end
          end
        elseif not belt_io.is_ours(e.name) then
          local r = unswappable_role(e, d)
          if r then
            if tile_port then
              refuse("two-unswappable", tx, ty)
            else
              port.kind, port.role = "tile", r
              tile_port = port
            end
          end
        end
        if port.kind == "edge" then
          local far = groups.block_at(si, tx + v[1], ty + v[2])
          if far then
            local fg = groups.get(groups.of(far))
            if fg and fg.force_index == group.force_index then
              port.kind, port.far = "shared", far
            else
              refuse("other-force", tx, ty)
              port.kind = nil
            end
          elseif not edge_belt and controlled(e) then
            -- Ruling 7: an edge cannot carry wires or control behaviour, so a wired or
            -- controlled belt is left untouched and served by the block-tile interface
            if tile_port then
              refuse("wired-belt", tx, ty)
              port.kind = nil
            else
              port.kind = "tile"
              tile_port = port
            end
          end
        end
        if port.kind and port.kind ~= "tile" then
          add(port)
        end
      end
    end

    -- inserters reaching the block tile
    local take, put = false, false
    local area = { { b.x - reach, b.y - reach }, { b.x + 1 + reach, b.y + 1 + reach } }
    for _, ins in ipairs(s.find_entities_filtered({ area = area, type = "inserter", force = group.force })) do
      local px, py = floor_pos(ins.pickup_position)
      local dx, dy = floor_pos(ins.drop_position)
      take = take or (px == b.x and py == b.y)
      put = put or (dx == b.x and dy == b.y)
    end
    if take and put then
      refuse("inserter-both", b.x, b.y)
    elseif take or put then
      if tile_port then
        refuse("port-tile-taken", b.x, b.y)
      else
        add({ kind = "inserter", role = take and "out" or "in", block = b.unit, bx = b.x, by = b.y, tx = b.x, ty = b.y })
      end
    end
    if tile_port then
      add(tile_port)
    end
  end
  return result
end

-- Copies the items of every transport line of `e` into a new script inventory (one slot per
-- belt stack, so item data and spoilage are kept). Returns the inventory and the list
-- { line, position, slot, count }. The caller puts them back (belt_io.put_back) or empties and
-- destroys the inventory.
---@param e LuaEntity
---@return LuaInventory, { line: integer, position: number, slot: integer, count: integer }[]
function belt_io.lift(e)
  local found = {}
  for li = 1, e.get_max_transport_line_index() do
    for _, d in ipairs(e.get_transport_line(li --[[@as defines.transport_line]]).get_detailed_contents()) do
      found[#found + 1] = { line = li, position = d.position, stack = d.stack }
    end
  end
  local inv = game.create_inventory(math.max(1, #found))
  local items = {}
  for k, it in ipairs(found) do
    inv[k].set_stack(it.stack)
    items[k] = { line = it.line, position = it.position, slot = k, count = it.stack.count }
  end
  return inv, items
end

-- Puts items lifted by belt_io.lift onto `e`: each on its own line at its own position if that is
-- free, else at the first free position of that line, else force-inserted at its position
-- (squashed, never dropped). Destroys `inv`.
---@param e LuaEntity
---@param inv LuaInventory
function belt_io.put_back(e, inv, items)
  local nlines = e.get_max_transport_line_index() --[[@as integer]]
  for _, it in ipairs(items) do
    local line = e.get_transport_line(math.min(it.line, nlines) --[[@as defines.transport_line]])
    local st = inv[it.slot] --[[@as LuaItemStack]]
    local len = line.line_length
    local pos = math.min(it.position, len)
    if not line.insert_at(pos, st, it.count) then
      local done = false
      local p = 0.0
      while not done and p <= len do
        done = line.insert_at(p, st, it.count)
        p = p + 0.03125
      end
      if not done then
        line.force_insert_at(pos, st, it.count)
      end
    end
  end
  inv.destroy()
end

-- Swaps a plain belt for the edge of its belt and `role`, keeping its direction, force,
-- quality, health and items. Returns the edge, or nil (the belt is left as it was) if the edge cannot
-- be created.
---@param belt LuaEntity
---@param role string "in" | "out"
---@return LuaEntity?
function belt_io.swap(belt, role)
  local name = belt_io.edge_name(belt.name, role)
  if not name then
    return nil
  end
  local s, pos, dir, force, quality, belt_name = belt.surface, belt.position, belt.direction, belt.force, belt.quality, belt.name
  local health = belt.health
  local inv, items = belt_io.lift(belt)
  belt.destroy()
  local edge = s.create_entity({
    name = name, position = pos, direction = dir, type = role == "in" and "input" or "output",
    force = force, quality = quality, create_build_effect_smoke = false,
  })
  if not edge then
    local back = assert(s.create_entity({ name = belt_name, position = pos, direction = dir, force = force, quality = quality, create_build_effect_smoke = false }),
      "modular-balancer: could not put back " .. belt_name)
    back.health = health
    belt_io.put_back(back, inv, items)
    return nil
  end
  edge.health = health
  belt_io.put_back(edge, inv, items)
  return edge
end

-- Swaps an edge back for its plain belt (direction, force, quality, health and items kept). Returns the
-- belt.
---@param edge LuaEntity
---@return LuaEntity
function belt_io.unswap(edge)
  local belt = assert(belt_io.edge_belt(edge.name))
  local s, pos, dir, force, quality = edge.surface, edge.position, edge.direction, edge.force, edge.quality
  local health = edge.health
  local inv, items = belt_io.lift(edge)
  edge.destroy()
  local e = assert(s.create_entity({ name = belt, position = pos, direction = dir, force = force, quality = quality, create_build_effect_smoke = false }),
    "modular-balancer: could not put back " .. belt)
  e.health = health
  belt_io.put_back(e, inv, items)
  return e
end

-- No belt-connectable feeds `e` or is fed by it.
---@param e LuaEntity
local function free(e)
  local nb = e.belt_neighbours
  return #nb.inputs == 0 and #nb.outputs == 0
end

-- Puts linked belt `name` of type `ltype` ("input" | "output") on block tile (bx, by), facing
-- one of `dirs`. With one direction (block-tile interface) it simply faces it. With several
-- (inserter port, F3 facing rule) it keeps the first direction where no belt-connectable feeds
-- it or is fed by it. A suitable linked belt already there is kept; any other one of the mod's
-- on that tile is replaced and its items moved onto the new one. Returns the linked belt, or
-- nil when no direction is free; then it also returns the replaced belt's items (a script
-- inventory, or nil) for the caller to put elsewhere.
---@param s LuaSurface
---@param dirs defines.direction[]
---@param force LuaForce
---@return LuaEntity?, LuaInventory?
function belt_io.block_port(s, bx, by, name, ltype, dirs, force)
  local check = #dirs > 1
  local old = belt_io.block_tile_belt(s, bx, by)
  if old and old.name == name and old.linked_belt_type == ltype and old.force.index == force.index then
    local ok = not check or free(old)
    if ok then
      for _, d in ipairs(dirs) do
        if old.direction == d then
          return old
        end
      end
    end
  end
  local inv, items
  if old then
    inv, items = belt_io.lift(old)
    old.destroy()
  end
  local pos = { bx + 0.5, by + 0.5 }
  for _, d in ipairs(dirs) do
    local e = s.create_entity({ name = name, position = pos, direction = d, type = ltype, force = force, create_build_effect_smoke = false })
    if e then
      if not check or free(e) then
        if inv then
          belt_io.put_back(e, inv, items)
        end
        return e
      end
      e.destroy()
    end
  end
  return nil, inv
end

-- Takes every item off a belt-connectable `e` into a new script inventory (merged stacks) and
-- returns it; the caller empties and destroys it.
---@param e LuaEntity
---@return LuaInventory
function belt_io.take_items(e)
  local inv, items = belt_io.lift(e)
  local merged = game.create_inventory(math.max(1, #items))
  for i = 1, #inv do
    if inv[i].valid_for_read then
      merged.insert(inv[i])
    end
  end
  inv.destroy()
  merged.sort_and_merge()
  return merged
end

-- Spills every stack of `inv` on the ground at `position` (marked to be looted) and destroys it.
---@param inv LuaInventory
---@param s LuaSurface
---@param position MapPosition
function belt_io.spill(inv, s, position)
  for i = 1, #inv do
    local st = inv[i] --[[@as LuaItemStack]]
    if st.valid_for_read then
      s.spill_item_stack({ position = position, stack = st, enable_looted = true, allow_belts = false, drop_full_stack = true })
    end
  end
  inv.destroy()
end

-- The tiles `entity` covers: x1, y1, x2, y2 (inclusive).
---@param entity LuaEntity
---@return integer, integer, integer, integer
function belt_io.tiles_of(entity)
  local x, y = entity.position.x --[[@as number]], entity.position.y --[[@as number]]
  local hw, hh = entity.tile_width / 2, entity.tile_height / 2
  return math.floor(x - hw + 0.01), math.floor(y - hh + 0.01), math.floor(x + hw - 0.01), math.floor(y + hh - 0.01)
end

-- True when a tile under `entity` holds a balancer block.
---@param entity LuaEntity
function belt_io.on_block_tile(entity)
  local si = entity.surface_index
  local x1, y1, x2, y2 = belt_io.tiles_of(entity)
  for x = x1, x2 do
    for y = y1, y2 do
      if groups.block_at(si, x, y) then
        return true
      end
    end
  end
  return false
end

-- A belt-connectable on block tile (x, y) of `s` other than the mod's block-tile linked belts
-- (edges count: a block cannot be built on an edge either), or nil.
---@param s LuaSurface
---@return LuaEntity?
function belt_io.foreign_belt_on(s, x, y)
  for _, e in ipairs(s.find_entities_filtered({ area = tile_area(x, y), type = belt_io.BELT_TYPES })) do
    if e.name:sub(1, #HIDDEN_LB) ~= HIDDEN_LB then
      return e
    end
  end
  return nil
end

-- Ruling 6: undoes a build that put a belt-connectable on a block tile (or a block on a belt).
-- The entity is mined with its contents and handed back to the player or robot that built it;
-- what does not fit (or with no builder) is spilled where it stood. Shows `reason` as flying
-- text to the player. No item is lost.
---@param entity LuaEntity
---@param event table the build event (player_index, robot)
---@param reason string
function belt_io.give_back(entity, event, reason)
  local s, pos = entity.surface, entity.position
  local inv = game.create_inventory(64)
  entity.mine({ inventory = inv, force = true, ignore_minable = true, raise_destroyed = false })
  local player = event.player_index and game.get_player(event.player_index)
  local robot = event.robot
  local target
  if player and player.valid then
    target = player
  elseif robot and robot.valid then
    target = robot.get_inventory(defines.inventory.robot_cargo)
  end
  for i = 1, #inv do
    local st = inv[i]
    if st.valid_for_read and target then
      local n = target.insert(st)
      if n >= st.count then
        st.clear()
      else
        st.count = st.count - n
      end
    end
  end
  belt_io.spill(inv, s, pos)
  if player and player.valid then
    player.create_local_flying_text({ text = { "mb-message." .. reason }, position = pos, surface = s })
  end
end

return belt_io
