-- Build and remove events of the visible balancer blocks, routed to scripts/groups.lua.
--   built:   on_built_entity, on_robot_built_entity, on_space_platform_built_entity,
--            script_raised_built, script_raised_revive, on_entity_cloned (the destination)
--   removed: on_player_mined_entity, on_robot_mined_entity, on_space_platform_mined_entity,
--            on_entity_died, script_raised_destroy
--   moved:   script_raised_teleported
--   forces:  on_forces_merged (the blocks of the source force now belong to the destination)
--   anything else (LuaEntity::destroy without raise_destroy, a deleted surface):
--            on_object_destroyed, for every block registered with register_on_object_destroyed
--            when it was built
-- Every event but on_object_destroyed and on_forces_merged (neither takes filters) carries a
-- name filter for the block prototypes of this game (MODDING-RULES §3), so the handlers only see
-- blocks. A mod has one handler per event: control.lua must not register these events anywhere
-- else.
local groups = require("scripts.groups")

local events = {}

local E = defines.events

-- Name filters for the block prototypes that exist (turbo only with Space Age).
local function filters()
  local list = {}
  for _, tier in ipairs(groups.TIERS) do
    local name = "mb-balancer-" .. tier
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.entity[name] then
      list[#list + 1] = { filter = "name", name = name }
    end
  end
  return list
end

local function built(entity)
  if entity and entity.valid then
    script.register_on_object_destroyed(entity)
    groups.on_block_built(entity)
  end
end

local function removed(entity)
  if entity and entity.valid then
    groups.on_block_removed(entity)
  end
end

function events.register()
  local f = filters()
  local on_built = function(event)
    built(event.entity)
  end
  for _, id in ipairs({ E.on_built_entity, E.on_robot_built_entity, E.on_space_platform_built_entity, E.script_raised_built, E.script_raised_revive }) do
    script.on_event(id, on_built, f)
  end
  script.on_event(E.on_entity_cloned, function(event)
    built(event.destination)
  end, f)
  local on_removed = function(event)
    removed(event.entity)
  end
  for _, id in ipairs({ E.on_player_mined_entity, E.on_robot_mined_entity, E.on_space_platform_mined_entity, E.on_entity_died, E.script_raised_destroy }) do
    script.on_event(id, on_removed, f)
  end
  script.on_event(E.script_raised_teleported, function(event)
    if event.entity.valid then
      groups.on_block_moved(event.entity)
    end
  end, f)
  script.on_event(E.on_forces_merged, function(event)
    groups.on_forces_merged(event.source_index, event.destination)
  end)
  script.on_event(E.on_object_destroyed, function(event)
    if event.type == defines.target_type.entity then
      groups.on_block_destroyed(event.useful_id)
    end
  end)
end

return events
