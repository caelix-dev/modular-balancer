-- Build and remove events of the visible balancer blocks and of everything that can change a
-- balancer's ports (belt-connectables and inserters), routed to scripts/groups.lua and
-- scripts/balancer.lua.
--   built:   on_built_entity, on_robot_built_entity, on_space_platform_built_entity,
--            script_raised_built, script_raised_revive, on_entity_cloned (the destination)
--   removed: on_player_mined_entity, on_robot_mined_entity, on_space_platform_mined_entity,
--            on_entity_died, script_raised_destroy
--   moved:   script_raised_teleported
--   changed: on_player_rotated_entity, on_player_flipped_entity, on_entity_settings_pasted
--            (the inserter positions or a belt direction change; between two blocks, the
--            balancer settings, scripts/gui.lua)
--   settings (scripts/gui.lua): on_gui_checked_state_changed, on_gui_closed, on_gui_click (the
--            close button), on_player_left_game / on_player_removed (GUI state cleanup),
--            on_player_changed_position / on_player_controller_changed (a frame whose block is
--            out of reach closes; work only while that player has a frame open), and the linked
--            custom inputs mb-open-gui, mb-copy-settings, mb-paste-settings
--   forces:  on_forces_merged (the blocks of the source force now belong to the destination)
--   lifecycle (scripts/lifecycle.lua):
--            on_player_setup_blueprint, on_player_configured_blueprint (edges become belts),
--            on_undo_applied, on_redo_applied, on_marked_for_upgrade and on_cancelled_upgrade
--            of transport belts, underground belts, splitters and edges, on_pre_surface_deleted /
--            on_pre_surface_cleared and on_surface_deleted / on_surface_cleared (the hidden
--            surface)
--   anything else (LuaEntity::destroy without raise_destroy, a deleted surface):
--            on_object_destroyed, for every block registered with register_on_object_destroyed
--            when it was built
-- Every event that takes filters carries name filters for the block prototypes of this game and
-- type filters for belt-connectables and inserters (MODDING-RULES §3). Blocks go to the groups;
-- the groups they change and the groups near any other entity are marked for the next balancer
-- flush (coalesced, one refresh per group per batch of events). A belt-connectable built on a
-- block tile, or a block built on one, is undone and handed back (Ruling 6). The build events
-- also take ghosts of linked belts: a ghost of an edge becomes a ghost of its belt, and an edge
-- built by the game (not by this mod, which raises no event for its own swaps) is kept only if
-- a group claims it at the next flush. The player or robot that mines the last block of a group
-- gets its network's items (scripts/balancer.lua). A mod has one handler per event: control.lua
-- must not register these events anywhere else.
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")
local belt_io = require("scripts.io")
local lifecycle = require("scripts.lifecycle")
local gui = require("scripts.gui")

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
  if entity.type == "entity-ghost" then
    if groups.tier_of(entity.ghost_name) then
      -- a block ghost on a belt (the block does not collide with belts, so the game marks
      -- nothing, not even for a forced build): the belt is marked for deconstruction, and the
      -- block replaces it when it is built (below)
      local p = entity.position
      local belt = belt_io.foreign_belt_on(entity.surface, math.floor(p.x), math.floor(p.y))
      if belt and not belt.to_be_deconstructed() then
        belt.order_deconstruction(entity.force, player and game.get_player(player) or nil)
      end
    end
    if not lifecycle.unghost(entity, player) then
      lifecycle.replace_orphan_ghost(entity)
    end
    return
  end
  if belt_io.edge_belt(entity.name) or (entity.name:sub(1, 22) == "mb-hidden-linked-belt-" and entity.surface_index ~= storage.surface_index) then
    -- an edge or a block-tile linked belt built by the game (a clone, a ghost, another mod): kept
    -- only if a port claims it at the next flush
    balancer.add_loose(entity, player)
    return
  end
  if groups.tier_of(entity.name) and lifecycle.replace_orphan(entity) then
    return -- a block of a tier whose belt is gone was replaced (its build event did the rest)
  end
  if groups.tier_of(entity.name) then
    local p = entity.position
    local belt = belt_io.foreign_belt_on(entity.surface, math.floor(p.x), math.floor(p.y))
    if belt and belt.to_be_deconstructed() then
      -- the belt a block ghost marked (above), still there because the robot built the block
      -- first: the block replaces it
      belt_io.clear_for_block(belt, event, entity.force)
    elseif belt then
      belt_io.give_back(entity, event, "block-on-belt")
      return
    end
    script.register_on_object_destroyed(entity)
    -- a block from a blueprint carries its balancer's settings (a new group takes them); a clone
    -- takes its source's group's
    local settings = gui.settings_from_tags(event.tags)
    if not settings and event.source and event.source.valid and groups.of(event.source.unit_number) then
      settings = groups.settings(groups.of(event.source.unit_number))
    end
    local ids, gone = groups.on_block_built(entity, settings)
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
    balancer.set_sink(gone, event.player_index, event.robot, event.platform)
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

-- The handlers of the rotate and flip events, for tests (headless tests have no player, so
-- LuaEntity::rotate and ::flip raise nothing).
function events.on_rotated(event)
  changed(event.entity, event)
end
events.on_flipped = events.on_rotated

-- on_entity_settings_pasted: between two blocks, the destination's balancer takes the source's
-- settings (scripts/gui.lua); otherwise the inserter or belt changed. A field for tests.
function events.on_settings_pasted(event)
  local src, dst = event.source, event.destination
  if src and src.valid and dst and dst.valid and groups.tier_of(src.name) and groups.tier_of(dst.name) then
    gui.paste(src, dst, event.player_index)
  else
    changed(dst, event)
  end
end

function events.register()
  local f = filters()
  local fb = filters()
  fb[#fb + 1] = { filter = "ghost_type", type = "linked-belt" }
  for _, tier in ipairs(groups.TIERS) do
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.entity["mb-balancer-" .. tier] then
      fb[#fb + 1] = { filter = "ghost_name", name = "mb-balancer-" .. tier }
    end
  end
  local on_built = function(event)
    built(event.entity, event)
  end
  for _, id in ipairs({ E.on_built_entity, E.script_raised_built, E.script_raised_revive }) do
    script.on_event(id, on_built, fb)
  end
  for _, id in ipairs({ E.on_robot_built_entity, E.on_space_platform_built_entity }) do
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
    local osi, op = event.old_surface_index, event.old_position
    local ox, oy = math.floor(op.x --[[@as number]]), math.floor(op.y --[[@as number]])
    if groups.tier_of(entity.name) then
      local ids, gone = groups.on_block_moved(entity)
      balancer.mark(ids, gone)
      balancer.mark_block(entity)
      balancer.mark_block_at(osi, ox, oy)
    elseif relevant(entity) then
      balancer.mark_near(entity)
      balancer.mark_around(osi, ox, oy, entity.type == "inserter" and belt_io.reach() or 2)
    end
  end, f)
  script.on_event(E.on_player_rotated_entity, events.on_rotated)
  script.on_event(E.on_player_flipped_entity, events.on_flipped)
  script.on_event(E.on_entity_settings_pasted, events.on_settings_pasted)
  script.on_event(E.on_gui_checked_state_changed, gui.on_checked)
  script.on_event(E.on_gui_closed, gui.on_closed)
  script.on_event(E.on_gui_click, gui.on_click)
  script.on_event(E.on_player_left_game, gui.on_left)
  script.on_event(E.on_player_removed, gui.on_removed)
  script.on_event(E.on_player_changed_position, gui.on_moved)
  script.on_event(E.on_player_controller_changed, gui.on_moved)
  script.on_event("mb-open-gui", gui.on_open_input)
  script.on_event("mb-copy-settings", gui.on_copy_input)
  script.on_event("mb-paste-settings", gui.on_paste_input)
  script.on_event(E.on_forces_merged, function(event)
    local ids, gone = groups.on_forces_merged(event.source_index, event.destination)
    balancer.mark(ids, gone)
  end)
  script.on_event(E.on_player_setup_blueprint, lifecycle.on_player_setup_blueprint)
  script.on_event(E.on_player_configured_blueprint, lifecycle.on_player_configured_blueprint)
  script.on_event(E.on_undo_applied, function(event)
    lifecycle.on_undo_redo(event, true)
  end)
  script.on_event(E.on_redo_applied, function(event)
    lifecycle.on_undo_redo(event, false)
  end)
  local belts = {
    { filter = "type", type = "transport-belt" }, { filter = "type", type = "underground-belt" },
    { filter = "type", type = "splitter" }, { filter = "type", type = "linked-belt" },
  }
  script.on_event(E.on_marked_for_upgrade, lifecycle.on_marked_for_upgrade, belts)
  script.on_event(E.on_cancelled_upgrade, lifecycle.on_cancelled_upgrade, belts)
  script.on_event(E.on_pre_surface_deleted, lifecycle.on_pre_surface_gone)
  script.on_event(E.on_pre_surface_cleared, lifecycle.on_pre_surface_gone)
  script.on_event(E.on_surface_deleted, lifecycle.on_surface_gone)
  script.on_event(E.on_surface_cleared, lifecycle.on_surface_gone)
  script.on_event(E.on_object_destroyed, function(event)
    if event.type == defines.target_type.entity then
      local si, x, y = groups.where(event.useful_id)
      local ids, gone = groups.on_block_destroyed(event.useful_id)
      balancer.mark(ids, gone)
      if si then
        balancer.mark_block_at(si, x, y)
      end
    end
  end)
end

return events
