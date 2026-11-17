-- The per-balancer settings and their small GUI.
--
-- Two settings per group of blocks, stored on the group (scripts/groups.lua, which also handles
-- merges: the larger group's settings win, and splits: every part keeps them):
--   lanes    "Balance lanes": lane splitters on every input, so both lanes of every output carry
--            the same (network.build balance_lanes). Default off.
--   recirc   "Redistribute unused shares": every output's unused share goes back into the network
--            (network.build recirc). Default on; off builds the plain network, which costs less
--            engine time (docs/benchmarks.md).
-- Changing one marks the group dirty; the next flush rebuilds its network with the items carried
-- over (scripts/balancer.lua).
--
-- How the settings travel:
--   GUI          clicking a block (the open-gui control, through the linked custom input
--                mb-open-gui: a simple-entity-with-owner has no GUI of its own) opens a small
--                frame with the two checkboxes; it is the player's opened GUI, so E or Esc
--                closes it, and its title bar has a close button. It closes by itself when its
--                block goes away or out of reach, and shows the current ratio after each flush.
--   one rule     opening and pasting need a block of the player's force within reach, or remote
--                view (gui.can_use), and the player's permission group must allow open-gui,
--                copy- and paste-entity-settings.
--   paste        on_entity_settings_pasted between two blocks, and the copy-entity-settings and
--                paste-entity-settings controls (linked custom inputs mb-copy-settings and
--                mb-paste-settings, since the game may not treat a simple-entity-with-owner as
--                having settings to paste): the destination's group takes the source's settings.
--   blueprints   on_player_setup_blueprint writes both settings as tags on every block
--                (gui.tag_blueprint, called from scripts/lifecycle.lua); a block built with those
--                tags that starts a new group gives it those settings (scripts/events.lua). A
--                block that joins an existing group takes that group's settings.
--   clones       a cloned block that starts a new group takes its source group's settings.
--   ghosts       the frame, copy and paste work on block ghosts too. A ghost has no group yet, so
--                its settings are tags on the ghost (the blueprint tags above), written on every
--                ghost of the same block connected to it edge to edge (gui.ghost_cluster), so the
--                group they start when built has them whichever is built first. Built blocks
--                those ghosts touch are the balancer they will join: the frame shows that
--                balancer's settings, and a change goes to it as well as to the ghosts. When the
--                ghost is built, its frame moves to the new block.
--
-- Item filters (scripts/filters.lua) belong to one block, not to the group: the frame's lower part
-- shows and changes the filter of the block it was opened on (on a ghost: its tag mb_filter, that
-- ghost only). Copy and paste carry the group settings and the block's filter (within one group,
-- the filter only); blueprints tag every block with its filter; a clone takes its source's; an
-- upgraded block (another tier on the same tile) keeps it. With "per lane" on, slots 3 to 5 and
-- "exclude" keep their values but are locked.
--
-- storage.mb_gui = {
--   open = { [player index] = LuaEntity },                     the block or block ghost whose
--                                                              GUI is open
--   where = { [player index] = { si, x, y, name } },           the tile of an open ghost, to
--                                                              find the block built from it
--   copy = { [player index] = LuaEntity },                     the block or ghost copied by the
--                                                              copy-entity-settings control;
--                                                              its current settings are pasted
-- }
-- Both are cleared for a removed player. A refused rebuild (its new network could not be placed)
-- sets the group's settings back to those of the network it keeps (gui.after_flush). A drain that
-- waits for room (refusal "drain-stuck") is not a refusal of the settings: the new network, with
-- the new settings, already works.
-- Everything runs in events, so all players compute the same (multiplayer-safe); nothing is done
-- in on_load.
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")
local filters = require("scripts.filters")

local gui = {}

local FRAME = "mb_settings"
local TAG_LANES, TAG_RECIRC = "mb_lanes", "mb_recirc"
local TAG_FILTER = "mb_filter"

-- How player indices become players: game.get_player, replaced by tests (a headless test has no
-- LuaPlayer, tests/game/lanes.lua uses a stand-in). Not state: the same function on every peer.
---@type fun(index: integer): LuaPlayer?
gui.lookup_player = function(index)
  return game.get_player(index)
end

local function state()
  storage.mb_gui = storage.mb_gui or { open = {}, copy = {} }
  storage.mb_gui.where = storage.mb_gui.where or {}
  return storage.mb_gui --[[@as { open: table<integer, LuaEntity>, where: table<integer, table>, copy: table<integer, LuaEntity> }]]
end

---@param e LuaEntity?
---@return boolean
local function is_block(e)
  return e ~= nil and e.valid and groups.tier_of(e.name) ~= nil
end

-- The group of block `e`, or nil.
---@param e LuaEntity?
---@return integer?
local function group_of(e)
  return is_block(e) and groups.of((e --[[@as LuaEntity]]).unit_number) or nil
end

-- True for a ghost of a balancer block.
---@param e LuaEntity?
---@return boolean
local function is_ghost(e)
  return e ~= nil and e.valid and e.type == "entity-ghost" and groups.tier_of(e.ghost_name) ~= nil
end

-- A block or a block ghost: what the frame, copy and paste work on.
---@param e LuaEntity?
---@return boolean
local function is_target(e)
  return is_block(e) or is_ghost(e)
end

local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The ghosts of the same block (name, force, surface) connected to ghost `g` edge to edge, `g`
-- first, and the ids of the groups of the built blocks of that tier and force they touch (the
-- balancer they join when built), in id order. Runs only on a GUI action, or on a flush while a
-- ghost's frame is open.
---@param g LuaEntity
---@return LuaEntity[], integer[]
function gui.ghost_cluster(g)
  local surface, name, force = g.surface, g.ghost_name, g.force --[[@as LuaForce]]
  local si, tier = surface.index, groups.tier_of(name)
  ---@type table<any, boolean>
  local seen = {}
  seen[g.unit_number] = true
  local list, todo, touched = {}, { g }, {}
  local i = 1
  while todo[i] do
    local e = todo[i]
    i = i + 1
    list[#list + 1] = e
    local x, y = math.floor(e.position.x --[[@as number]]), math.floor(e.position.y --[[@as number]])
    for _, d in ipairs(SIDES) do
      local nx, ny = x + d[1], y + d[2]
      local unit = groups.block_at(si, nx, ny)
      local grp = unit and groups.get(groups.of(unit))
      if grp then
        if grp.tier == tier and grp.force_index == force.index then
          touched[grp.id] = true
        end
      else
        for _, n in ipairs(surface.find_entities_filtered({ ghost_name = name, force = force, position = { nx + 0.5, ny + 0.5 } })) do
          if not seen[n.unit_number] then
            seen[n.unit_number] = true
            todo[#todo + 1] = n
          end
        end
      end
    end
  end
  local ids = {}
  for id in pairs(touched) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return list, ids
end

-- Of the groups `ids` (in id order), the one a merge keeps: the most blocks, the lower id on a
-- tie (scripts/groups.lua).
---@param ids integer[]
---@return integer?
local function merge_winner(ids)
  local best, most = nil, -1
  for _, id in ipairs(ids) do
    local g = groups.get(id)
    if g and g.count > most then
      best, most = id, g.count
    end
  end
  return best
end

-- The group whose settings and ratio block or ghost `e` shows: a block's own; for a ghost, the
-- balancer its cluster will join, or nil.
---@param e LuaEntity
---@return integer?
local function shown_group(e)
  if is_ghost(e) then
    local _, ids = gui.ghost_cluster(e)
    return merge_winner(ids)
  end
  return group_of(e)
end

-- Shows the settings and ratio of block or ghost `target` in `frame`.
---@param frame LuaGuiElement
---@param target LuaEntity
local function fill(frame, target)
  local inner = frame.mb_inner
  if not inner then
    return
  end
  local s = gui.settings_of(target)
  inner.mb_lanes.state = s.lanes
  inner.mb_recirc.state = s.recirc
  -- the filter part (tests may hand in a frame without it)
  local f = gui.filter_of(target) or { items = {}, exclude = false, lanes = false }
  local slots, flags = inner.mb_slots, inner.mb_fflags
  ---@diagnostic disable-next-line: unnecessary-if
  if slots and flags then
    for i = 1, filters.SLOTS do
      local b = slots["mb_slot" .. i]
      local v = f.items[i]
      -- an item of a removed mod stays in the record but cannot be shown
      b.elem_value = (v and v ~= "" and prototypes.item[v]) and v or nil
      b.enabled = not (f.lanes and i > 2)
      if f.lanes and i == 1 then
        b.tooltip = { "mb-gui.slot-left" }
      elseif f.lanes and i == 2 then
        b.tooltip = { "mb-gui.slot-right" }
      else
        b.tooltip = ""
      end
    end
    flags.mb_exclude.state = f.exclude
    flags.mb_exclude.enabled = not f.lanes
    flags.mb_flanes.state = f.lanes
  end
  local id = shown_group(target)
  local rec = id and balancer.get(id)
  if rec and rec.placed then
    inner.mb_ratio.caption = { "mb-gui.ratio", rec.n, rec.m }
  elseif is_ghost(target) then
    inner.mb_ratio.caption = { "mb-gui.ghost" }
  else
    inner.mb_ratio.caption = { "mb-gui.idle" }
  end
end

-- Shows the current settings in every open GUI.
function gui.refresh_all()
  for pi, target in pairs(state().open) do
    local player = gui.lookup_player(pi)
    local frame = player and player.valid and player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
    if frame and is_target(target) then
      fill(frame, target)
    end
  end
end

-- Sets group `id`'s settings (fields left nil are kept). When one changed, the group is marked
-- so the next flush rebuilds its network (items carried over), and open GUIs show the change.
-- Returns true when a setting changed.
---@param id integer?
---@param s { lanes: boolean?, recirc: boolean? }
---@param player_index integer?
---@return boolean
function gui.set(id, s, player_index)
  if not (id and groups.set_settings(id, s)) then
    return false
  end
  balancer.mark({ id }, nil, player_index)
  gui.refresh_all()
  return true
end

-- The settings of block or ghost `e`: its group's for a block; for a ghost, those of the
-- balancer it will join, or else its own tags, or else the defaults.
---@param e LuaEntity
---@return { lanes: boolean, recirc: boolean }
function gui.settings_of(e)
  if is_ghost(e) then
    local id = shown_group(e)
    if id then
      return groups.settings(id)
    end
    local s = gui.settings_from_tags(e.tags) or {}
    return { lanes = s.lanes == true, recirc = s.recirc ~= false }
  end
  return groups.settings(group_of(e))
end

-- Gives block or ghost `e` settings `s` (fields left nil are kept): a block's group; for a
-- ghost, the tags of its whole cluster and the groups the cluster touches. Returns true when a
-- setting changed.
---@param e LuaEntity
---@param s { lanes: boolean?, recirc: boolean? }
---@param player_index integer?
---@return boolean
function gui.apply(e, s, player_index)
  if not is_ghost(e) then
    return gui.set(group_of(e), s, player_index)
  end
  local old = gui.settings_of(e)
  local full = { lanes = old.lanes, recirc = old.recirc }
  if s.lanes ~= nil then
    full.lanes = s.lanes
  end
  if s.recirc ~= nil then
    full.recirc = s.recirc
  end
  local list, ids = gui.ghost_cluster(e)
  local changed = false
  for _, g in ipairs(list) do
    local t = g.tags or {}
    if t[TAG_LANES] ~= full.lanes or t[TAG_RECIRC] ~= full.recirc then
      t[TAG_LANES], t[TAG_RECIRC] = full.lanes, full.recirc
      g.tags = t
      changed = true
    end
  end
  for _, id in ipairs(ids) do
    if gui.set(id, full, player_index) then
      changed = true
    end
  end
  if changed then
    gui.refresh_all()
  end
  return changed
end

-- Copies the settings of `source` to `destination` (each a block or a block ghost). Returns true
-- when a setting changed.
---@param source LuaEntity
---@param destination LuaEntity
---@param player_index integer?
---@return boolean
function gui.paste(source, destination, player_index)
  if not (is_target(source) and is_target(destination)) or source == destination then
    return false
  end
  local from, to = group_of(source), group_of(destination)
  local changed = false
  if not (from and from == to) then
    changed = gui.apply(destination, gui.settings_of(source), player_index)
  end
  if gui.set_filter(destination, gui.filter_of(source), player_index) then
    changed = true
  end
  return changed
end

-- The settings in the tags of a block built from a blueprint, or nil when it has none.
---@param tags Tags?
---@return { lanes: boolean?, recirc: boolean? }?
function gui.settings_from_tags(tags)
  if type(tags) ~= "table" or (tags[TAG_LANES] == nil and tags[TAG_RECIRC] == nil) then
    return nil
  end
  return { lanes = tags[TAG_LANES] == true, recirc = tags[TAG_RECIRC] ~= false }
end

-- The item filter in the tags of a built block or a ghost, or nil.
---@param tags Tags?
---@return table?
function gui.filter_from_tags(tags)
  return type(tags) == "table" and filters.normalize(tags[TAG_FILTER]) or nil
end

-- The item filter of block or ghost `e` (a scripts/filters.lua record), or nil.
---@param e LuaEntity
---@return table?
function gui.filter_of(e)
  if is_ghost(e) then
    return gui.filter_from_tags(e.tags)
  end
  return is_block(e) and groups.filter(e.unit_number) or nil
end

-- Gives block or ghost `e` item filter `f` (nil clears it). A block's group is marked, so the
-- next flush rebuilds its network. Returns true when the filter changed.
---@param e LuaEntity
---@param f table?
---@param player_index integer?
---@return boolean
function gui.set_filter(e, f, player_index)
  f = filters.normalize(f)
  if is_ghost(e) then
    local t = e.tags or {}
    if filters.same(t[TAG_FILTER], f) then
      return false
    end
    t[TAG_FILTER] = f
    e.tags = t
  else
    local id = group_of(e)
    if not (id and groups.set_filter(e.unit_number, f)) then
      return false
    end
    balancer.mark({ id }, nil, player_index)
  end
  gui.refresh_all()
  return true
end

-- Writes the settings of each block's group as tags on its blueprint entity. `map` is the
-- blueprint index to source entity mapping (on_player_setup_blueprint). Only entries whose
-- blueprint entity has the source block's name are tagged, so a blueprint the mapping does not
-- belong to is left alone. Returns the number of blocks tagged.
---@param bp LuaItemStack|LuaRecord
---@param map table<integer, LuaEntity>?
---@return integer
function gui.tag_blueprint(bp, map)
  if not (map and bp and bp.valid and bp.is_blueprint_setup()) then
    return 0
  end
  local count = bp.get_blueprint_entity_count()
  local entities
  local n = 0
  for i, e in pairs(map) do
    local id = group_of(e)
    if id and i >= 1 and i <= count then
      entities = entities or bp.get_blueprint_entities() or {}
      local be = entities[i]
      if be and be.name == e.name then
        local s = groups.settings(id)
        bp.set_blueprint_entity_tag(i, TAG_LANES, s.lanes)
        bp.set_blueprint_entity_tag(i, TAG_RECIRC, s.recirc)
        local f = groups.filter(e.unit_number)
        if f then
          bp.set_blueprint_entity_tag(i, TAG_FILTER, f)
        end
        n = n + 1
      end
    end
  end
  return n
end

-- Whether `player`'s permission group allows `action` (defines.input_action); no group allows
-- everything.
---@param player LuaPlayer
---@param action defines.input_action
---@return boolean
local function allowed(player, action)
  local pg = player.permission_group
  return pg == nil or pg.allows_action(action)
end

-- The one rule for opening a block's settings and for pasting settings onto it: a block or block
-- ghost of the player's force that the player can reach, or any such one in remote view (2.x
-- opens entity GUIs and pastes settings from the map).
---@param player LuaPlayer
---@param e LuaEntity?
---@return boolean
function gui.can_use(player, e)
  if not is_target(e) then
    return false
  end
  ---@cast e LuaEntity
  return e.force.index == player.force.index
    and (player.controller_type == defines.controllers.remote or player.can_reach_entity(e))
end

-- Closes the settings GUI of `player` (if open).
---@param player LuaPlayer
function gui.close(player)
  local st = state()
  st.open[player.index] = nil
  st.where[player.index] = nil
  local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
  if frame then
    frame.destroy()
  end
end

-- Opens the settings GUI of block or block ghost `block` for `player`: a frame with the standard
-- draggable title bar and close button, the ratio and the two checkboxes.
---@param player LuaPlayer
---@param block LuaEntity
function gui.open(player, block)
  if not (group_of(block) or is_ghost(block)) then
    return
  end
  gui.close(player)
  local frame = player.gui.screen.add({ type = "frame", name = FRAME, direction = "vertical" })
  local bar = frame.add({ type = "flow", name = "mb_titlebar", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "label", caption = { "mb-gui.title" }, style = "frame_title", ignored_by_interaction = true })
  local space = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  space.style.horizontally_stretchable = true
  space.style.height = 24
  space.style.right_margin = 4
  bar.add({ type = "sprite-button", name = "mb_close", style = "frame_action_button", sprite = "utility/close",
    tooltip = { "gui.close-instruction" }, tags = { mb_close = true } })
  local inner = frame.add({ type = "frame", name = "mb_inner", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.add({ type = "label", name = "mb_ratio", caption = "" })
  inner.add({ type = "checkbox", name = "mb_lanes", state = false, caption = { "mb-gui.balance-lanes" },
    tooltip = { "mb-gui.balance-lanes-tooltip" }, tags = { mb_setting = "lanes" } })
  inner.add({ type = "checkbox", name = "mb_recirc", state = true, caption = { "mb-gui.recirc" },
    tooltip = { "mb-gui.recirc-tooltip" }, tags = { mb_setting = "recirc" } })
  inner.add({ type = "line", direction = "horizontal" })
  inner.add({ type = "label", caption = { "mb-gui.filter" }, tooltip = { "mb-gui.filter-tooltip" }, style = "caption_label" })
  local slots = inner.add({ type = "flow", name = "mb_slots", direction = "horizontal" })
  for i = 1, filters.SLOTS do
    slots.add({ type = "choose-elem-button", name = "mb_slot" .. i, elem_type = "item", style = "slot_button",
      elem_filters = { { filter = "hidden", invert = true } }, tags = { mb_slot = i } })
  end
  local flags = inner.add({ type = "flow", name = "mb_fflags", direction = "horizontal" })
  flags.add({ type = "checkbox", name = "mb_exclude", state = false, caption = { "mb-gui.exclude" },
    tooltip = { "mb-gui.exclude-tooltip" }, tags = { mb_setting = "exclude" } })
  flags.add({ type = "checkbox", name = "mb_flanes", state = false, caption = { "mb-gui.filter-lanes" },
    tooltip = { "mb-gui.filter-lanes-tooltip" }, tags = { mb_setting = "flanes" } })
  fill(frame, block)
  frame.auto_center = true
  local st = state()
  st.open[player.index] = block
  if is_ghost(block) then
    st.where[player.index] = { si = block.surface_index, x = math.floor(block.position.x --[[@as number]]),
      y = math.floor(block.position.y --[[@as number]]), name = block.ghost_name }
  end
  player.opened = frame
end

-- Re-checks the open settings GUI of `player`: closed when its block is gone, out of reach
-- (gui.can_use) or no longer allowed, refreshed otherwise.
---@param player LuaPlayer
function gui.check(player)
  local st = state()
  local block = st.open[player.index]
  if block == nil then
    return
  end
  local w = st.where[player.index]
  if w and not is_ghost(block) then
    -- the ghost was built (or removed): the frame moves to the block built in its place
    local unit = groups.block_at(w.si, w.x, w.y)
    local built = unit and groups.entity(unit)
    if built and built.valid and built.name == w.name then
      block = built
      st.open[player.index] = built
    end
    st.where[player.index] = nil
  end
  if not ((group_of(block) or is_ghost(block)) and gui.can_use(player, block) and allowed(player, defines.input_action.open_gui)) then
    gui.close(player)
    return
  end
  local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
  if frame then
    fill(frame, block)
    if player.opened_gui_type == defines.gui_type.none then
      -- the game let go of it without on_gui_closed (measured, F11: leaving remote view by
      -- script); opened again so E and Esc still close it
      player.opened = frame
    end
  else
    state().open[player.index] = nil
  end
end

-- The open-gui control for `player` (a LuaPlayer, or in tests a table with the fields read here
-- and by gui.can_use): opens the GUI of the block under the cursor. Returns true when it opened.
---@param player LuaPlayer
---@return boolean
function gui.open_input(player)
  local e = player.selected
  if not gui.can_use(player, e) or not player.is_cursor_empty() or not allowed(player, defines.input_action.open_gui) then
    return false
  end
  ---@cast e LuaEntity
  gui.open(player, e)
  return true
end

-- The copy-entity-settings control: remembers the block or block ghost under the cursor
-- (anything else clears it). Its settings are read when they are pasted, as vanilla pastes the source's current
-- settings.
---@param player LuaPlayer
function gui.copy_input(player)
  local e = player.selected
  local st = state()
  if is_target(e) and allowed(player, defines.input_action.copy_entity_settings) then
    st.copy[player.index] = e
  else
    st.copy[player.index] = nil
  end
end

-- The paste-entity-settings control: gives the block or block ghost under the cursor the
-- current settings of the copied one; nothing when that one is gone (as vanilla). Returns true when a setting
-- changed.
---@param player LuaPlayer
---@return boolean
function gui.paste_input(player)
  local src = state().copy[player.index]
  local dst = player.selected
  if not (src and is_target(src) and gui.can_use(player, dst) and allowed(player, defines.input_action.paste_entity_settings)) then
    return false
  end
  ---@cast dst LuaEntity
  return gui.paste(src, dst, player.index)
end

-- A checkbox of the frame of `player` changed. Returns true when a setting changed.
---@param player LuaPlayer
---@param el LuaGuiElement
---@return boolean
function gui.checked(player, el)
  local key = el.valid and el.tags and el.tags.mb_setting
  if key ~= "lanes" and key ~= "recirc" and key ~= "exclude" and key ~= "flanes" then
    return false
  end
  local block = state().open[player.index]
  if not ((group_of(block) or is_ghost(block)) and gui.can_use(player, block) and allowed(player, defines.input_action.open_gui)) then
    gui.close(player) -- the block is gone or out of reach
    return false
  end
  ---@cast block LuaEntity
  local changed
  if key == "exclude" or key == "flanes" then
    local f = filters.normalize(gui.filter_of(block)) or { items = { "", "", "", "", "" }, exclude = false, lanes = false }
    if key == "exclude" then
      f.exclude = el.state
    else
      f.lanes = el.state
    end
    changed = gui.set_filter(block, f, player.index)
  else
    changed = gui.apply(block, { [key] = el.state }, player.index)
  end
  if not changed then
    local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
    if frame then
      fill(frame, block)
    end
  end
  return changed
end

-- A filter slot of the frame of `player` changed. Returns true when the filter changed.
---@param player LuaPlayer
---@param el LuaGuiElement
---@return boolean
function gui.elem_changed(player, el)
  local i = el.valid and el.tags and el.tags.mb_slot
  if type(i) ~= "number" then
    return false
  end
  local block = state().open[player.index]
  if not ((group_of(block) or is_ghost(block)) and gui.can_use(player, block) and allowed(player, defines.input_action.open_gui)) then
    gui.close(player)
    return false
  end
  ---@cast block LuaEntity
  local f = filters.normalize(gui.filter_of(block)) or { items = { "", "", "", "", "" }, exclude = false, lanes = false }
  local v = el.elem_value
  f.items[i] = type(v) == "string" and v or ""
  local changed = gui.set_filter(block, f, player.index)
  if not changed then
    local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
    if frame then
      fill(frame, block)
    end
  end
  return changed
end

-- Forgets everything kept for player `index` (on_player_removed): its open block and its
-- copied block, so a new player who gets the index inherits nothing.
---@param index integer
function gui.forget(index)
  local st = state()
  st.open[index] = nil
  st.where[index] = nil
  st.copy[index] = nil
end

-- After every balancer flush (balancer.after_flush): a group whose rebuild was refused keeps its
-- old network, so its settings go back to those of that network (the checkboxes show what
-- the balancer does; the refusal message says the old balancer and its settings are kept), and
-- every open GUI is checked again (its block may be gone, or its ratio changed).
---@param refreshed integer[]
function gui.after_flush(refreshed)
  for _, gid in ipairs(refreshed) do
    local rec = balancer.get(gid)
    if rec and rec.placed and groups.get(gid) then
      for _, r in ipairs(rec.refused) do
        if r.reason == "rebuild-failed" then
          groups.set_settings(gid, { lanes = rec.lanes == true, recirc = rec.recirc ~= false })
          break
        end
      end
    end
  end
  local st = storage.mb_gui
  if not (st and next(st.open)) then
    return
  end
  local list = {}
  for pi in pairs(st.open) do
    list[#list + 1] = pi
  end
  table.sort(list)
  for _, pi in ipairs(list) do
    local player = gui.lookup_player(pi)
    if player and player.valid then
      gui.check(player)
    else
      st.open[pi] = nil
    end
  end
end
balancer.after_flush = gui.after_flush

-- Event handlers (scripts/events.lua registers them).

---@return LuaPlayer?
local function player_of(event)
  local player = gui.lookup_player(event.player_index)
  return player and player.valid and player or nil
end

---@param event EventData.CustomInputEvent
function gui.on_open_input(event)
  local player = player_of(event)
  if player then
    gui.open_input(player)
  end
end

---@param event EventData.CustomInputEvent
function gui.on_copy_input(event)
  local player = player_of(event)
  if player then
    gui.copy_input(player)
  end
end

---@param event EventData.CustomInputEvent
function gui.on_paste_input(event)
  local player = player_of(event)
  if player then
    gui.paste_input(player)
  end
end

---@param event EventData.on_gui_checked_state_changed
function gui.on_checked(event)
  local player = player_of(event)
  if player then
    gui.checked(player, event.element)
  end
end

---@param event EventData.on_gui_elem_changed
function gui.on_elem_changed(event)
  local player = player_of(event)
  if player then
    gui.elem_changed(player, event.element)
  end
end

---@param event EventData.on_gui_click
function gui.on_click(event)
  local el = event.element
  if el.valid and el.name == "mb_close" and el.tags and el.tags.mb_close then
    local player = player_of(event)
    if player then
      gui.close(player)
    end
  end
end

---@param event EventData.on_gui_closed
function gui.on_closed(event)
  local el = event.element
  if el and el.valid and el.name == FRAME then
    local player = player_of(event)
    if player then
      gui.close(player)
    end
  end
end

-- on_player_left_game: the frame would stay on screen after a reload.
---@param event EventData.on_player_left_game
function gui.on_left(event)
  local player = player_of(event)
  if player then
    gui.close(player)
  end
end

---@param event EventData.on_player_removed
function gui.on_removed(event)
  gui.forget(event.player_index)
end

-- on_player_changed_position and on_player_controller_changed: a frame whose block is now out of
-- reach closes. Only a player with an open frame does any work.
---@param event EventData.on_player_changed_position|EventData.on_player_controller_changed
function gui.on_moved(event)
  local st = storage.mb_gui
  if st and st.open[event.player_index] then
    local player = player_of(event)
    if player then
      gui.check(player)
    end
  end
end

return gui
