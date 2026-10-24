-- What players and other mods do to a balancer besides building and removing it: blueprints and
-- copy-paste, ghosts, undo/redo, the upgrade planner, configuration changes (a removed tier, a
-- lost hidden surface). Called from scripts/events.lua (events) and control.lua
-- (on_configuration_changed). Runs only on those events.
--
-- Edges (docs/feasibility.md F1) are the mod's linked belts standing in for the last tile of a
-- player's belt. They must never leave the world as edges:
--   blueprints, copy-paste   on_player_setup_blueprint rewrites every edge to the belt it replaced
--                            (no link, no linked belt type), so a paste builds plain belts that
--                            the balancer swaps again where they touch a block. The block-tile
--                            linked belts are `not-blueprintable` and never appear.
--   ghosts                   a ghost of an edge (an undo record of a mined edge, an old blueprint,
--                            another mod) is replaced by a ghost of its belt.
--   undo                     undoing the build of a belt that has since become an edge orders the
--                            edge's deconstruction (the undo finds no belt of that name there).
--                            Undoing the removal of a block or an edge rebuilds a block or a belt
--                            ghost; the balancer swaps the belt again when it is built.
--   upgrade planner          the planner never selects an edge (another prototype). When it marks
--                            the belt next to an edge of the same belt, the edge is swapped back
--                            to its belt and that belt gets the same upgrade order, so robots
--                            upgrade it like the rest of the line (the player pays for it and
--                            gets the old belt back). Until it is upgraded it is not a port
--                            (scripts/io.lua); then it is swapped for the new belt's edge.
-- Belts with circuit wires or control behaviour are never swapped (Ruling 7), so blueprints, undo
-- and upgrades see them as the player built them.
--
-- Configuration changes (control.lua on_configuration_changed):
--   a tier whose belt is gone (turbo after Space Age was removed): its blocks are replaced by
--   blocks of the fastest remaining tier, in place, and the players are told. The hidden turbo
--   prototypes stay defined without Space Age (prototypes/hidden.lua, prototypes/blocks.lua), so
--   the networks and their items survive the load, and the next flush moves their items into the
--   new tier's networks (scripts/balancer.lua, retire by tile).
--   the hidden surface missing (deleted while the mod was absent): logged; the networks are
--   dropped (their entities are gone) and placed again on a new surface.
-- The hidden surface deleted or cleared at runtime (on_pre_surface_deleted,
-- on_pre_surface_cleared): every network's items are spilled at its blocks first, then every
-- network is placed again on a new surface (balancer.drop_networks).
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")
local belt_io = require("scripts.io")

local lifecycle = {}

-- Rewrites the edges in a list of BlueprintEntity to the belts they replaced. Returns true if any
-- entry changed.
---@param entities BlueprintEntity[]
---@return boolean
function lifecycle.clean_entities(entities)
  local changed = false
  for _, be in ipairs(entities) do
    local belt = belt_io.edge_belt(be.name --[[@as string]])
    if belt then
      be.name = belt
      be.type = nil
      be.belt_link = nil
      changed = true
    end
  end
  return changed
end

-- Rewrites the edges of a blueprint (LuaItemStack or LuaRecord) to belts. Returns the number of
-- edges rewritten.
---@param bp LuaItemStack|LuaRecord
---@return integer
function lifecycle.clean_blueprint(bp)
  if not (bp and bp.valid and bp.is_blueprint_setup()) then
    return 0
  end
  local entities = bp.get_blueprint_entities()
  if not entities then
    return 0
  end
  local n = 0
  for _, be in ipairs(entities) do
    if belt_io.edge_belt(be.name --[[@as string]]) then
      n = n + 1
    end
  end
  if n > 0 then
    lifecycle.clean_entities(entities)
    -- only names change: keep every position (a record with absolute snapping keeps its grid)
    bp.set_blueprint_entities(entities, false)
  end
  return n
end

-- The blueprint in item stack `st`: the stack itself, or the active blueprint of a blueprint book
-- (nested books followed). nil for anything else (a copy-paste tool, an empty book).
---@param st LuaItemStack?
---@return LuaItemStack?
local function stack_blueprint(st, depth)
  depth = depth or 0
  if not (st and st.valid and st.valid_for_read) or depth > 8 then
    return nil
  end
  if st.is_blueprint then
    return st
  end
  if st.is_blueprint_book then
    local index = st.active_index
    local inv = index and st.get_inventory(defines.inventory.item_main)
    if inv and index <= #inv then
      return stack_blueprint(inv[index --[[@as integer]]] --[[@as LuaItemStack]], depth + 1)
    end
  end
  return nil
end

-- The blueprint in record `r`: the record itself, or the selected record of a blueprint book
-- record for `player` (nested books followed).
---@param r LuaRecord?
---@param player LuaPlayer?
---@return LuaRecord?
local function record_blueprint(r, player, depth)
  depth = depth or 0
  if not (r and r.valid) or depth > 8 then
    return nil
  end
  if r.type == "blueprint" then
    return r
  end
  if r.type == "blueprint-book" and player and player.valid then
    return record_blueprint(r.get_selected_record(player), player, depth + 1)
  end
  return nil
end

-- on_player_setup_blueprint (also raised for copy and cut, and for a blueprint reassigned from
-- the library): every place the selected blueprint can be in is cleaned, since which one holds it
-- depends on the path (a new blueprint, a book, a library record, the copy tool's blueprint in the
-- cursor or in blueprint_to_setup). Cleaning is idempotent, so cleaning several is harmless.
--   event.record   the library record being reassigned (or the selected record of a book record)
--   event.stack    the item used to select: a blueprint, or a book (its active blueprint)
--   player.blueprint_to_setup, player.cursor_stack (a blueprint, or a book's active blueprint)
function lifecycle.on_player_setup_blueprint(event)
  local pi = event.player_index
  local player = pi and pi > 0 and game.get_player(pi) or nil
  local record = record_blueprint(event.record, player)
  if record and record.is_blueprint_setup() then
    lifecycle.clean_blueprint(record)
  end
  local stacks = { event.stack }
  if player and player.valid then
    stacks[#stacks + 1] = player.blueprint_to_setup
    stacks[#stacks + 1] = player.cursor_stack
  end
  for _, st in ipairs(stacks) do
    local bp = stack_blueprint(st)
    if bp and bp.is_blueprint_setup() then
      lifecycle.clean_blueprint(bp)
    end
  end
end

-- on_player_configured_blueprint: the confirmed blueprint is in the cursor.
function lifecycle.on_player_configured_blueprint(event)
  local player = game.get_player(event.player_index)
  local bp = player and player.valid and stack_blueprint(player.cursor_stack) or nil
  if bp and bp.is_blueprint_setup() then
    lifecycle.clean_blueprint(bp)
  end
end

-- A ghost of an edge becomes a ghost of its belt (same position, direction, force and quality).
-- Returns the new ghost, or nil if `ghost` is not an edge ghost.
-- The new ghost is created for the player who placed the old one (`player_index`, else the old
-- ghost's last user), so it joins that player's undo item: Ctrl+Z of the paste removes it too.
---@param ghost LuaEntity
---@param player_index integer?
---@return LuaEntity?
function lifecycle.unghost(ghost, player_index)
  if not (ghost.valid and ghost.type == "entity-ghost") then
    return nil
  end
  local belt = belt_io.edge_belt(ghost.ghost_name)
  if not belt then
    return nil
  end
  local s, pos, dir, force, quality = ghost.surface, ghost.position, ghost.direction, ghost.force, ghost.quality
  local player = player_index and player_index > 0 and game.get_player(player_index) or ghost.last_user
  ghost.destroy()
  return s.create_entity({
    name = "entity-ghost", inner_name = belt, position = pos, direction = dir, force = force, quality = quality,
    player = player, create_build_effect_smoke = false,
  })
end

-- The edge ghosts on the tile of `position` of surface `s` become belt ghosts.
---@param s LuaSurface
---@param position MapPosition
---@param player_index integer?
local function unghost_at(s, position, player_index)
  local x, y = math.floor((position.x or position[1]) --[[@as number]]), math.floor((position.y or position[2]) --[[@as number]])
  for _, g in ipairs(s.find_entities_filtered({ area = { { x + 0.1, y + 0.1 }, { x + 0.9, y + 0.9 } }, type = "entity-ghost" })) do
    lifecycle.unghost(g, player_index)
  end
end

-- on_undo_applied / on_redo_applied. `actions` are UndoRedoAction tables.
-- - built-entity of a belt whose tile is now an edge of that belt (undo of a build): the game
--   finds no entity of that name there, so the edge is marked for deconstruction instead.
-- - removed-entity of an edge (undo of mining an edge): the ghost it left is made a belt ghost.
-- - upgraded-entity of a belt whose tile is now an edge (the line was upgraded, then its last tile
--   swapped): the game finds no belt of that name there, so the edge is swapped back to its belt
--   and given the order the game meant (undo: back to original_name; redo: to the target), as
--   the upgrade planner path does.
-- - rotated-entity of an edge is not handled: a rotation that changed the edge's role swapped it
--   for another edge prototype, so the undo finds nothing (the player rotates it back by hand).
---@param event { player_index: integer, actions: UndoRedoAction[] }
---@param undo boolean
function lifecycle.on_undo_redo(event, undo)
  local pi = event.player_index
  local player = pi and pi > 0 and game.get_player(pi) or nil
  for _, a in ipairs(event.actions or {}) do
    local t = a.target
    local s = a.surface_index and game.get_surface(a.surface_index) or (player and player.valid and player.surface) or nil
    if t and s then
      if a.type == "removed-entity" and belt_io.edge_belt(t.name --[[@as string]]) then
        unghost_at(s, t.position, pi)
      elseif a.type == "upgraded-entity" then
        local from = undo and t.name or a.original_name
        local to = undo and { name = a.original_name, quality = a.original_quality_name } or { name = t.name, quality = t.quality or "normal" }
        local p = t.position
        local x, y = math.floor((p.x or p[1]) --[[@as number]]), math.floor((p.y or p[2]) --[[@as number]])
        for _, e in ipairs(s.find_entities_filtered({ area = { { x + 0.1, y + 0.1 }, { x + 0.9, y + 0.9 } }, type = "linked-belt" })) do
          if belt_io.edge_belt(e.name) == from then
            local force = e.force
            local belt = belt_io.unswap(e)
            belt.order_upgrade({ target = to, force = force, player = player })
            balancer.mark_near(belt, pi)
          end
        end
      elseif undo and a.type == "built-entity" then
        local p = t.position
        local x, y = math.floor((p.x or p[1]) --[[@as number]]), math.floor((p.y or p[2]) --[[@as number]])
        for _, e in ipairs(s.find_entities_filtered({ area = { { x + 0.1, y + 0.1 }, { x + 0.9, y + 0.9 } }, type = "linked-belt" })) do
          if belt_io.edge_belt(e.name) == t.name and not e.to_be_deconstructed() then
            e.order_deconstruction(e.force, player and player.valid and player or nil)
          end
        end
      end
    end
  end
end

-- on_marked_for_upgrade of a transport belt (filtered): an edge of the same belt fed by it or
-- feeding it is swapped back to its belt, which gets the same upgrade order.
function lifecycle.on_marked_for_upgrade(event)
  local e = event.entity
  if not (e and e.valid and e.type == "transport-belt") or belt_io.is_ours(e.name) then
    return
  end
  local nb = e.belt_neighbours
  local edges = {}
  for _, list in ipairs({ nb.inputs, nb.outputs }) do
    for _, n in ipairs(list) do
      if n.valid and belt_io.edge_belt(n.name) == e.name then
        edges[#edges + 1] = n
      end
    end
  end
  if #edges == 0 then
    return
  end
  local target = { name = event.target.name, quality = event.quality.name }
  local player = event.player_index and game.get_player(event.player_index) or nil
  for _, edge in ipairs(edges) do
    if edge.valid then
      local force = edge.force
      local belt = belt_io.unswap(edge)
      belt.order_upgrade({ target = target, force = force, player = player })
      balancer.mark_near(belt, event.player_index)
    end
  end
end

-- on_cancelled_upgrade of a transport belt: the belt can be a port again.
function lifecycle.on_cancelled_upgrade(event)
  local e = event.entity
  if e and e.valid then
    balancer.mark_near(e, event.player_index)
  end
end

-- Tiers whose belt prototype is missing (turbo without Space Age), and the fastest tier left.
---@return table<string, boolean>, string?
local function orphan_tiers()
  local belts = { basic = "transport-belt", fast = "fast-transport-belt", express = "express-transport-belt", turbo = "turbo-transport-belt" }
  local orphans, best = {}, nil
  for _, tier in ipairs(groups.TIERS) do
    ---@diagnostic disable-next-line: unnecessary-if
    if prototypes.entity[belts[tier]] then
      best = tier
    else
      orphans[tier] = true
    end
  end
  return orphans, best
end

-- A block of a tier whose belt is gone (a leftover turbo block item or ghost placed after Space
-- Age was removed) is replaced at once by a block of the fastest tier left (raise_built: its own
-- build event joins it to a group). Returns true if `entity` was replaced.
---@param entity LuaEntity a block, just built
---@return boolean
function lifecycle.replace_orphan(entity)
  local orphans, best = orphan_tiers()
  local tier = groups.tier_of(entity.name)
  if not (tier and orphans[tier] and best) then
    return false
  end
  local s, pos, force, quality = entity.surface, entity.position, entity.force, entity.quality
  entity.destroy()
  local new = s.create_entity({
    name = "mb-balancer-" .. best, position = pos, force = force, quality = quality, raise_built = true,
    create_build_effect_smoke = false,
  })
  if not new then
    s.spill_item_stack({ position = pos, stack = { name = "mb-balancer-" .. best, count = 1, quality = quality.name }, enable_looted = true })
  end
  return true
end

-- The same for a ghost of such a block: it becomes a ghost of the fastest tier left.
---@param ghost LuaEntity
---@return boolean
function lifecycle.replace_orphan_ghost(ghost)
  if not (ghost.valid and ghost.type == "entity-ghost") then
    return false
  end
  local orphans, best = orphan_tiers()
  local tier = groups.tier_of(ghost.ghost_name)
  if not (tier and orphans[tier] and best) then
    return false
  end
  local s, pos, force, quality = ghost.surface, ghost.position, ghost.force, ghost.quality
  ghost.destroy()
  s.create_entity({ name = "entity-ghost", inner_name = "mb-balancer-" .. best, position = pos, force = force, quality = quality })
  return true
end

-- Replaces every block of a tier in `from` (a set of tier names) by a block of tier `to`, in
-- place (raise_destroy / raise_built, so the groups follow; the next flush carries each old
-- network's items into the new tier's network). Returns the number replaced.
---@param from table<string, boolean>
---@param to string
---@return integer
function lifecycle.downgrade(from, to)
  local list = {}
  for unit, rec in pairs(storage.groups and storage.groups.blocks or {}) do
    local e = rec.entity
    if e.valid and from[groups.tier_of(e.name) or ""] then
      list[#list + 1] = { unit = unit, entity = e }
    end
  end
  table.sort(list, function(a, b) return a.unit < b.unit end)
  local n = 0
  for _, b in ipairs(list) do
    local e = b.entity
    local s, pos, force, quality, health = e.surface, e.position, e.force, e.quality, e.health
    e.destroy({ raise_destroy = true })
    local new = s.create_entity({
      name = "mb-balancer-" .. to, position = pos, force = force, quality = quality, raise_built = true,
      create_build_effect_smoke = false,
    })
    if new and new.valid then
      new.health = health
      n = n + 1
    else
      -- cannot happen on the tile the block just left; never delete the block silently
      s.spill_item_stack({ position = pos, stack = { name = "mb-balancer-" .. to, count = 1, quality = quality.name }, enable_looted = true })
    end
  end
  if n > 0 then
    log("modular-balancer: " .. n .. " blocks of a removed tier replaced by " .. to .. " blocks")
    game.print({ "mb-message.tier-removed", n, { "entity-name.mb-balancer-" .. to } })
  end
  return n
end

-- Blocks of a tier whose belt is gone (turbo without Space Age) become blocks of the fastest
-- tier left. Returns the number replaced.
---@return integer
function lifecycle.downgrade_orphans()
  local orphans, best = orphan_tiers()
  if not best or not next(orphans) then
    return 0
  end
  return lifecycle.downgrade(orphans, best)
end

-- control.lua on_configuration_changed (after the groups dropped vanished blocks).
function lifecycle.on_configuration_changed()
  local si = storage.surface_index
  local hidden = si and game.get_surface(si)
  if si and not (hidden and hidden.valid) then
    log("modular-balancer: the hidden surface is gone; every balancer network is placed again")
    balancer.drop_networks() -- their entities are gone; releases their regions
    storage.surface_index, storage.regions = nil, nil
  end
  lifecycle.downgrade_orphans()
  balancer.mark_all()
end

---@param index integer
local function ours(index)
  return storage.surface_index ~= nil and index == storage.surface_index
end

-- on_pre_surface_deleted / on_pre_surface_cleared: see the header.
function lifecycle.on_pre_surface_gone(event)
  if ours(event.surface_index) then
    log("modular-balancer: the hidden surface is being deleted or cleared; networks spilled and placed again")
    balancer.drop_networks()
  end
end

-- on_surface_deleted / on_surface_cleared: the regions are free again (a new surface is created
-- by the next placement when the old one is gone).
function lifecycle.on_surface_gone(event)
  if ours(event.surface_index) then
    -- a network placed between the pre event and the clear (none measured) lost its entities:
    -- drop it (its region with it) and place it again
    local any = false
    for _, rec in pairs(storage.balancer and storage.balancer.recs or {}) do
      local first = rec.placed and rec.placed.entities[1]
      if first and not first.valid then
        any = true
      end
    end
    if any then
      log("modular-balancer: networks placed before the hidden surface was cleared are placed again")
      balancer.drop_networks()
    end
    storage.regions = nil
    if not game.get_surface(event.surface_index) then
      storage.surface_index = nil
    end
  end
end

return lifecycle
