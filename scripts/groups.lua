-- Connected groups of visible balancer blocks: blocks of one tier, one force and one surface
-- that touch edge to edge (4-neighbours) form one group, which becomes one balancer (spec
-- Update 2). Groups are merged when a block joins two or more of them and split when a removed
-- block was their only link. Runs only on build, remove and force-merge events
-- (scripts/events.lua).
--
-- storage.groups = {
--   next_id = integer,
--   by_id   = { [id] = mb.Group },
--   blocks  = { [unit_number] = mb.BlockRecord },
--   at      = { [surface_index] = { ["x,y"] = unit_number } },   x, y of the block's tile
-- }
--
-- Every change returns two lists: `ids`, the groups that exist and changed (a new block, a
-- merge result, the parts of a split, a group moved to another force), and `gone`, the groups
-- that no longer exist (merged away or emptied). A block destroyed without an event
-- (LuaEntity::destroy without raise_destroy) is removed when on_object_destroyed arrives, or
-- earlier when a build next to it finds it invalid; until then it still counts as a member.
--
-- Groups compare forces by index. `force` is kept for callers and is replaced when its force is
-- merged into another (game.merge_forces moves the entities without build or remove events).
-- A script that sets LuaEntity::force on a block raises no event either; that is not tracked.
--
-- Cost: a removal only floods the group when the removed block had two or more neighbours in
-- it, and stops as soon as all of them are reached, so taking a group apart from its ends is
-- O(1) per block. Callers that rebuild per changed group (Task 4) should coalesce: one rebuild
-- per group per batch of events, not one per event.
local groups = {}

local PREFIX = "mb-balancer-"

groups.TIERS = { "basic", "fast", "express", "turbo" }

---@class mb.Group
---@field id integer
---@field tier string
---@field surface_index integer
---@field force_index integer
---@field force LuaForce
---@field count integer number of blocks
---@field blocks table<integer, LuaEntity> unit_number -> block

---@class mb.BlockRecord
---@field entity LuaEntity
---@field group integer
---@field surface_index integer
---@field x integer
---@field y integer

---@class mb.GroupsState
---@field next_id integer
---@field by_id table<integer, mb.Group>
---@field blocks table<integer, mb.BlockRecord>
---@field at table<integer, table<string, integer>>

---@return mb.GroupsState
local function state()
  storage.groups = storage.groups or { next_id = 1, by_id = {}, blocks = {}, at = {} }
  return storage.groups
end

-- The block tier of an entity name, or nil when it is not a block.
---@param name string
---@return string?
function groups.tier_of(name)
  if name:sub(1, #PREFIX) == PREFIX then
    return name:sub(#PREFIX + 1)
  end
  return nil
end

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Unit numbers of the blocks on the 4 neighbour tiles of tile (x, y) on surface `si`.
---@param st mb.GroupsState
---@return integer[]
local function neighbours(st, si, x, y)
  local at = st.at[si]
  local out = {}
  if not at then
    return out
  end
  for _, o in ipairs(OFFSETS) do
    local u = at[(x + o[1]) .. "," .. (y + o[2])]
    ---@diagnostic disable-next-line: unnecessary-if
    if u then
      out[#out + 1] = u
    end
  end
  return out
end

---@param st mb.GroupsState
---@param force LuaForce
---@return mb.Group
local function new_group(st, tier, si, force)
  local id = st.next_id
  st.next_id = id + 1
  local g = { id = id, tier = tier, surface_index = si, force_index = force.index, force = force, count = 0, blocks = {} }
  st.by_id[id] = g
  return g
end

-- Puts block `unit` into group `g`, taking it out of its current group (left as it is otherwise).
---@param st mb.GroupsState
---@param g mb.Group
local function move_to(st, g, unit)
  local rec = st.blocks[unit]
  local from = st.by_id[rec.group]
  ---@diagnostic disable-next-line: unnecessary-if
  if from and from.blocks[unit] then
    from.blocks[unit] = nil
    from.count = from.count - 1
  end
  rec.group = g.id
  g.blocks[unit] = rec.entity
  g.count = g.count + 1
end

-- Moves every block of `g` into `target` and deletes `g`.
---@param st mb.GroupsState
---@param target mb.Group
---@param g mb.Group
local function absorb(st, target, g, gone)
  for u in pairs(g.blocks) do
    move_to(st, target, u)
  end
  st.by_id[g.id] = nil
  gone[#gone + 1] = g.id
end

-- The larger of two groups (the lower id on a tie) and the other one.
---@param a mb.Group
---@param b mb.Group
---@return mb.Group keep, mb.Group drop
local function larger(a, b)
  if a.count > b.count or (a.count == b.count and a.id < b.id) then
    return a, b
  end
  return b, a
end

-- Each id once: `ids` the ones that still exist, `gone` the ones that do not.
---@param st mb.GroupsState
---@return integer[] ids, integer[] gone
local function settle(st, ids, gone)
  local seen, live, dead = {}, {}, {}
  for _, list in ipairs({ ids, gone }) do
    for _, id in ipairs(list) do
      if not seen[id] then
        seen[id] = true
        ---@diagnostic disable-next-line: unnecessary-if
        if st.by_id[id] then
          live[#live + 1] = id
        else
          dead[#dead + 1] = id
        end
      end
    end
  end
  return live, dead
end

-- Flood fill within group `g` from `start`. Stops early, returning nil, once every unit in
-- `targets` (a set) has been reached; otherwise returns the list of units reached.
---@param st mb.GroupsState
---@param g mb.Group
---@return integer[]?
local function flood(st, g, start, seen, targets, n_targets)
  local part, queue = {}, { start }
  seen[start] = true
  while #queue > 0 do
    local u = table.remove(queue)
    part[#part + 1] = u
    if targets[u] then
      n_targets = n_targets - 1
      if n_targets == 0 then
        return nil
      end
    end
    local r = st.blocks[u]
    for _, v in ipairs(neighbours(st, g.surface_index, r.x, r.y)) do
      if g.blocks[v] and not seen[v] then
        seen[v] = true
        queue[#queue + 1] = v
      end
    end
  end
  return part
end

-- Removes block `unit` from its group and splits the group if it falls apart. Appends the
-- changed and removed group ids to `ids` and `gone`.
---@param st mb.GroupsState
---@param unit integer|uint64
local function remove(st, unit, ids, gone)
  local rec = st.blocks[unit]
  if not rec then
    return
  end
  local g = st.by_id[rec.group]
  g.blocks[unit] = nil
  g.count = g.count - 1
  st.blocks[unit] = nil
  local at = st.at[rec.surface_index]
  local key = rec.x .. "," .. rec.y
  if at and at[key] == unit then
    at[key] = nil
  end
  if g.count == 0 then
    st.by_id[g.id] = nil
    gone[#gone + 1] = g.id
    return
  end
  ids[#ids + 1] = g.id

  -- Every remaining block is connected to one of the removed block's neighbours in the group.
  -- With one such neighbour nothing can split; with more, the parts are the flood fills from
  -- them, and the first fill that reaches all of them shows there is no split.
  local starts, targets = {}, {}
  for _, u in ipairs(neighbours(st, rec.surface_index, rec.x, rec.y)) do
    if g.blocks[u] then
      starts[#starts + 1] = u
      targets[u] = true
    end
  end
  if #starts <= 1 then
    return
  end
  local seen, parts = {}, {}
  for _, start in ipairs(starts) do
    if not seen[start] then
      local part = flood(st, g, start, seen, targets, #starts)
      if not part then
        return
      end
      parts[#parts + 1] = part
    end
  end
  -- The largest part keeps the id.
  table.sort(parts, function(a, b)
    return #a > #b
  end)
  for i = 2, #parts do
    local ng = new_group(st, g.tier, g.surface_index, g.force)
    for _, u in ipairs(parts[i]) do
      move_to(st, ng, u)
    end
    ids[#ids + 1] = ng.id
  end
end

-- Removes the record of `unit` if its entity is no longer valid. Returns true when it did.
---@param st mb.GroupsState
local function drop_stale(st, unit, ids, gone)
  local rec = st.blocks[unit]
  if rec and not rec.entity.valid then
    remove(st, unit, ids, gone)
    return true
  end
  return false
end

---@param entity LuaEntity a block
---@return integer[] ids, integer[] gone
function groups.on_block_built(entity)
  local st = state()
  local ids, gone = {}, {}
  local unit = entity.valid and entity.unit_number
  local tier = unit and groups.tier_of(entity.name)
  ---@diagnostic disable-next-line: unnecessary-if
  if not unit or not tier or st.blocks[unit] then
    return ids, gone
  end
  local si = entity.surface_index
  local pos = entity.position
  local x, y = math.floor(pos.x --[[@as number]]), math.floor(pos.y --[[@as number]])
  local key = x .. "," .. y
  st.at[si] = st.at[si] or {}
  local old = st.at[si][key]
  ---@diagnostic disable-next-line: unnecessary-if
  if old then
    drop_stale(st, old, ids, gone)
    ---@diagnostic disable-next-line: unnecessary-if
    if st.at[si][key] then
      -- Another live block on the same tile: only a script can do that (create_entity does
      -- not check collisions). The tile keeps its first block; this one joins no group.
      log("modular-balancer: " .. entity.name .. " at " .. key .. " overlaps another block; it joins no balancer")
      return settle(st, ids, gone)
    end
  end
  st.blocks[unit] = { entity = entity, group = 0, surface_index = si, x = x, y = y }
  st.at[si][key] = unit

  -- Distinct same-tier, same-force neighbour groups.
  local fi = entity.force.index
  local found = {}
  ---@type mb.Group[]
  local list = {}
  for _, u in ipairs(neighbours(st, si, x, y)) do
    if not drop_stale(st, u, ids, gone) then
      local g = st.by_id[st.blocks[u].group]
      if g.tier == tier and g.force_index == fi and not found[g.id] then
        found[g.id] = true
        list[#list + 1] = g
      end
    end
  end

  ---@type mb.Group
  local target
  if #list == 0 then
    target = new_group(st, tier, si, entity.force --[[@as LuaForce]])
  else
    -- Merge into the largest group, so the fewest blocks move.
    table.sort(list, function(a, b)
      return (larger(a, b)) == a and a ~= b
    end)
    target = list[1] --[[@as mb.Group]]
    for i = 2, #list do
      absorb(st, target, list[i], gone)
    end
  end
  move_to(st, target, unit)
  ids[#ids + 1] = target.id
  return settle(st, ids, gone)
end

---@param entity LuaEntity a block, still valid (mined, died or script-raised destroy)
---@return integer[] ids, integer[] gone
function groups.on_block_removed(entity)
  local st, ids, gone = state(), {}, {}
  local unit = entity.unit_number
  if unit then
    remove(st, unit, ids, gone)
  end
  return settle(st, ids, gone)
end

-- on_object_destroyed of a block (useful_id is its unit number). Nothing when it is already gone.
---@param unit integer|uint64
---@return integer[] ids, integer[] gone
function groups.on_block_destroyed(unit)
  local st, ids, gone = state(), {}, {}
  remove(st, unit, ids, gone)
  return settle(st, ids, gone)
end

-- A block moved by script (script_raised_teleported): leaves its old place, joins at the new one.
---@param entity LuaEntity
---@return integer[] ids, integer[] gone
function groups.on_block_moved(entity)
  local st, ids, gone = state(), {}, {}
  local unit = entity.unit_number
  if unit then
    remove(st, unit, ids, gone)
  end
  local i2, g2 = groups.on_block_built(entity)
  for _, id in ipairs(i2) do
    ids[#ids + 1] = id
  end
  for _, id in ipairs(g2) do
    gone[#gone + 1] = id
  end
  return settle(st, ids, gone)
end

-- on_forces_merged: the groups of the source force now belong to `destination`, and those that
-- touch a destination group of the same tier merge with it.
---@param source_index integer
---@param destination LuaForce
---@return integer[] ids, integer[] gone
function groups.on_forces_merged(source_index, destination)
  local st, ids, gone = state(), {}, {}
  local moved = {}
  for id, g in pairs(st.by_id) do
    if g.force_index == source_index then
      g.force_index = destination.index
      g.force = destination
      moved[#moved + 1] = id
    end
  end
  table.sort(moved)
  for _, id in ipairs(moved) do
    local g = st.by_id[id]
    -- `g` may already have been absorbed by an earlier moved group.
    ---@diagnostic disable-next-line: unnecessary-if
    if g then
      ids[#ids + 1] = id
      local units = {}
      for u in pairs(g.blocks) do
        units[#units + 1] = u
      end
      table.sort(units)
      for _, u in ipairs(units) do
        local r = st.blocks[u]
        for _, v in ipairs(neighbours(st, r.surface_index, r.x, r.y)) do
          local mine, other = st.by_id[st.blocks[u].group], st.by_id[st.blocks[v].group]
          if mine ~= other and mine.tier == other.tier and mine.force_index == other.force_index then
            local keep, drop = larger(mine, other)
            absorb(st, keep, drop, gone)
            ids[#ids + 1] = keep.id
          end
        end
      end
    end
  end
  return settle(st, ids, gone)
end

---@param id integer?
---@return mb.Group?
function groups.get(id)
  return id and state().by_id[id] or nil
end

-- The group id of a block, or nil.
---@param unit integer|uint64|nil
---@return integer?
function groups.of(unit)
  local rec = unit and state().blocks[unit]
  return rec and rec.group
end

-- The block on tile (x, y) of surface `si`: its unit number, or nil.
---@param si integer
---@param x integer
---@param y integer
---@return integer?
function groups.block_at(si, x, y)
  local at = state().at[si]
  return at and at[x .. "," .. y] or nil
end

-- Where block `unit` is recorded: surface_index, x, y (still known when its entity is gone,
-- until it is removed from the groups), or nil.
---@param unit integer|uint64|nil
---@return integer?, integer?, integer?
function groups.where(unit)
  ---@type mb.BlockRecord?
  local rec = unit and state().blocks[unit] or nil
  if not rec then
    return nil
  end
  return rec.surface_index, rec.x, rec.y
end

-- The entity of block `unit`, or nil.
---@param unit integer|uint64|nil
---@return LuaEntity?
function groups.entity(unit)
  local rec = unit and state().blocks[unit]
  return rec and rec.entity
end

-- on_init: creates the storage tables.
function groups.init()
  state()
end

-- on_configuration_changed: drops blocks that vanished without an event (a removed prototype,
-- a deleted surface).
---@return integer[] ids, integer[] gone
function groups.on_configuration_changed()
  local st = state()
  local ids, gone, stale = {}, {}, {}
  for unit, rec in pairs(st.blocks) do
    if not rec.entity.valid then
      stale[#stale + 1] = unit
    end
  end
  table.sort(stale)
  for _, unit in ipairs(stale) do
    remove(st, unit, ids, gone)
  end
  return settle(st, ids, gone)
end

return groups
