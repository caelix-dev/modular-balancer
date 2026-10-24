-- Build and remove events of the visible balancer blocks and of everything that can change a
-- balancer's ports (belt-connectables and inserters), routed to scripts/groups.lua and
-- scripts/balancer.lua.
--   built:   on_built_entity, on_robot_built_entity, on_space_platform_built_entity,
--            script_raised_built, script_raised_revive, on_entity_cloned (the destination)
--   removed: on_player_mined_entity, on_robot_mined_entity, on_space_platform_mined_entity,
--            on_entity_died, script_raised_destroy
--   moved:   script_raised_teleported
--   changed: on_player_rotated_entity, on_player_flipped_entity, on_entity_settings_pasted
--            (the inserter positions or a belt direction change)
--   forces:  on_forces_merged (the blocks of the source force now belong to the destination)
--   anything else (LuaEntity::destroy without raise_destroy, a deleted surface):
--            on_object_destroyed, for every block registered with register_on_object_destroyed
--            when it was built
-- Every event that takes filters carries name filters for the block prototypes of this game and
-- type filters for belt-connectables and inserters (MODDING-RULES §3). Blocks go to the groups;
-- the groups they change and the groups near any other entity are marked for the next balancer
-- flush (coalesced, one refresh per group per batch of events). A belt-connectable built on a
-- block tile, or a block built on one, is undone and handed back (Ruling 6). A mod has one
-- handler per event: control.lua must not register these events anywhere else.
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")
local belt_io = require("scripts.io")

local events = {}

local E = defines.events

-- Name filters for the block prototypes that exist (turbo only with Space Age), and type
-- filters for belt-connectables and inserters.
local function filters()
  local list = {}
  for _, tier in ipairs(groups.TIERS) do
    local name = "mb-balancer-" .. tier
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.entity[name] then
      list[#list + 1] = { filter = "name", name = name }
    end
  end
  for _, t in ipairs(belt_io.BELT_TYPES) do
    list[#list + 1] = { filter = "type", type = t }
  end
  list[#list + 1] = { filter = "type", type = "inserter" }
  return list
end

local function relevant(entity)
  return entity.type == "inserter" or belt_io.IS_BELT_TYPE[entity.type]
end

local function built(entity, event)
  if not (entity and entity.valid) then
    return
  end
  local player = event.player_index
  if groups.tier_of(entity.name) then
    local p = entity.position
    if belt_io.foreign_belt_on(entity.surface, math.floor(p.x), math.floor(p.y)) then
      belt_io.give_back(entity, event, "block-on-belt")
      return
    end
    script.register_on_object_destroyed(entity)
    local ids, gone = groups.on_block_built(entity)
    balancer.mark(ids, gone, player)
    balancer.mark_block(entity, player)
  elseif relevant(entity) then
    if entity.type ~= "inserter" and not belt_io.is_ours(entity.name) and belt_io.on_block_tile(entity) then
      belt_io.give_back(entity, event, "belt-on-block")
      return
    end
    balancer.mark_near(entity, player)
  end
end

local function removed(entity, event)
  if not (entity and entity.valid) then
    return
  end
  if groups.tier_of(entity.name) then
    local ids, gone = groups.on_block_removed(entity)
    balancer.mark(ids, gone, event.player_index)
    balancer.mark_block(entity, event.player_index)
  elseif relevant(entity) then
    balancer.mark_near(entity, event.player_index)
  end
end

local function changed(entity, event)
  if entity and entity.valid and relevant(entity) then
    balancer.mark_near(entity, event.player_index)
  end
end

function events.register()
  local f = filters()
  local on_built = function(event)
    built(event.entity, event)
  end
  for _, id in ipairs({ E.on_built_entity, E.on_robot_built_entity, E.on_space_platform_built_entity, E.script_raised_built, E.script_raised_revive }) do
    script.on_event(id, on_built, f)
  end
  script.on_event(E.on_entity_cloned, function(event)
    built(event.destination, event)
  end, f)
  local on_removed = function(event)
    removed(event.entity, event)
  end
  for _, id in ipairs({ E.on_player_mined_entity, E.on_robot_mined_entity, E.on_space_platform_mined_entity, E.on_entity_died, E.script_raised_destroy }) do
    script.on_event(id, on_removed, f)
  end
  script.on_event(E.script_raised_teleported, function(event)
    local entity = event.entity
    if not entity.valid then
      return
    end
    if groups.tier_of(entity.name) then
      local ids, gone = groups.on_block_moved(entity)
      balancer.mark(ids, gone)
      balancer.mark_block(entity)
    elseif relevant(entity) then
      balancer.mark_near(entity)
    end
  end, f)
  script.on_event(E.on_player_rotated_entity, function(event)
    changed(event.entity, event)
  end)
  script.on_event(E.on_player_flipped_entity, function(event)
    changed(event.entity, event)
  end)
  script.on_event(E.on_entity_settings_pasted, function(event)
    changed(event.destination, event)
  end)
  script.on_event(E.on_forces_merged, function(event)
    local ids, gone = groups.on_forces_merged(event.source_index, event.destination)
    balancer.mark(ids, gone)
  end)
  script.on_event(E.on_object_destroyed, function(event)
    if event.type == defines.target_type.entity then
      local ids, gone = groups.on_block_destroyed(event.useful_id)
      balancer.mark(ids, gone)
    end
  end)
end

return events
