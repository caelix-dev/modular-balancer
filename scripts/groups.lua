-- Connected groups of visible balancer blocks: blocks of one tier, one force and one surface
-- that touch edge to edge (4-neighbours) form one group, which becomes one balancer (spec
-- Update 2). Groups are merged when a block joins two or more of them and split when a removed
-- block was their only link. Runs only on build and remove events (scripts/events.lua).
--
-- storage.groups = {
--   next_id = integer,
--   by_id   = { [id] = mb.Group },
--   blocks  = { [unit_number] = mb.BlockRecord },
--   at      = { [surface_index] = { ["x,y"] = unit_number } },   x, y of the block's tile
-- }
--
-- Every change returns two lists: `ids`, the groups that exist and changed (a new block, a
-- merge result, the parts of a split), and `gone`, the groups that no longer exist (merged away
-- or emptied). A block destroyed without an event (LuaEntity::destroy without raise_destroy) is
-- removed when on_object_destroyed arrives, or earlier when a build next to it finds it invalid;
-- until then it still counts as a member.
local groups = {}

local PREFIX = "mb-balancer-"

groups.TIERS = { "basic", "fast", "express", "turbo" }

---@class mb.Group
---@field id integer
---@field tier string
---@field surface_index integer
---@field force LuaForce
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
---@return mb.Group
local function new_group(st, tier, si, force)
  local id = st.next_id
  st.next_id = id + 1
  local g = { id = id, tier = tier, surface_index = si, force = force, blocks = {} }
  st.by_id[id] = g
  return g
end

---@param st mb.GroupsState
---@param g mb.Group
local function add_to(st, g, unit)
  local rec = st.blocks[unit]
  rec.group = g.id
  g.blocks[unit] = rec.entity
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

-- Removes block `unit` from its group and splits the group if it falls apart. Appends the
-- changed and removed group ids to `ids` and `gone`.
---@param st mb.GroupsState
---@param unit integer|uint64
local function remove(st, unit, ids, gone)
  local rec = st.blocks[unit]
  if not rec then
    return
  end
  st.blocks[unit] = nil
  local at = st.at[rec.surface_index]
  local key = rec.x .. "," .. rec.y
  if at and at[key] == unit then
    at[key] = nil
  end
  local g = st.by_id[rec.group]
  g.blocks[unit] = nil
  if next(g.blocks) == nil then
    st.by_id[g.id] = nil
    gone[#gone + 1] = g.id
    return
  end

  -- Every remaining block is connected to one of the removed block's neighbours in the group,
  -- so the parts are the flood fills from those neighbours.
  local seen, parts = {}, {}
  for _, start in ipairs(neighbours(st, rec.surface_index, rec.x, rec.y)) do
    if g.blocks[start] and not seen[start] then
      local part, queue, n = {}, { start }, 0
      seen[start] = true
      while #queue > 0 do
        local u = table.remove(queue)
        part[#part + 1] = u
        n = n + 1
        local r = st.blocks[u]
        for _, v in ipairs(neighbours(st, rec.surface_index, r.x, r.y)) do
          if g.blocks[v] and not seen[v] then
            seen[v] = true
            queue[#queue + 1] = v
          end
        end
      end
      parts[#parts + 1] = { units = part, n = n }
    end
  end
  ids[#ids + 1] = g.id
  -- The largest part keeps the id.
  table.sort(parts, function(a, b)
    return a.n > b.n
  end)
  for i = 2, #parts do
    local ng = new_group(st, g.tier, g.surface_index, g.force)
    for _, u in ipairs(parts[i].units) do
      g.blocks[u] = nil
      add_to(st, ng, u)
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
  end
  st.blocks[unit] = { entity = entity, group = 0, surface_index = si, x = x, y = y }
  st.at[si][key] = unit

  -- Distinct same-tier, same-force neighbour groups.
  local found = {}
  ---@type mb.Group[]
  local list = {}
  for _, u in ipairs(neighbours(st, si, x, y)) do
    if not drop_stale(st, u, ids, gone) then
      local g = st.by_id[st.blocks[u].group]
      if g.tier == tier and g.force.index == entity.force.index and not found[g.id] then
        found[g.id] = true
        list[#list + 1] = g
      end
    end
  end

  ---@type mb.Group
  local target
  if #list == 0 then
    target = new_group(st, tier, si, entity.force)
  else
    -- Merge into the largest group, so the fewest blocks move.
    local sizes = {}
    for _, g in ipairs(list) do
      sizes[g.id] = table_size(g.blocks)
    end
    table.sort(list, function(a, b)
      if sizes[a.id] ~= sizes[b.id] then
        return sizes[a.id] > sizes[b.id]
      end
      return a.id < b.id
    end)
    target = list[1] --[[@as mb.Group]]
    for i = 2, #list do
      local g = list[i]
      for u in pairs(g.blocks) do
        add_to(st, target, u)
      end
      st.by_id[g.id] = nil
      gone[#gone + 1] = g.id
    end
  end
  add_to(st, target, unit)
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
