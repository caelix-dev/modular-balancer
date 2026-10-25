-- The per-balancer settings (Plan 3 Task 3) and their small GUI.
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
--
-- storage.mb_gui = {
--   open = { [player index] = LuaEntity },                     the block whose GUI is open
--   copy = { [player index] = LuaEntity },                     the block copied by the
--                                                              copy-entity-settings control;
--                                                              its current settings are pasted
-- }
-- Both are cleared for a removed player. A rebuild refused for too many items sets the group's
-- settings back to those of the network it keeps (gui.after_flush).
-- Everything runs in events, so all players compute the same (multiplayer-safe); nothing is done
-- in on_load.
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")

local gui = {}

local FRAME = "mb_settings"
local TAG_LANES, TAG_RECIRC = "mb_lanes", "mb_recirc"

local function state()
  storage.mb_gui = storage.mb_gui or { open = {}, copy = {} }
  return storage.mb_gui --[[@as { open: table<integer, LuaEntity>, copy: table<integer, LuaEntity> }]]
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

---@param frame LuaGuiElement
---@param id integer?
local function fill(frame, id)
  local s = groups.settings(id)
  local inner = frame.mb_inner
  if not inner then
    return
  end
  inner.mb_lanes.state = s.lanes
  inner.mb_recirc.state = s.recirc
  local rec = balancer.get(id)
  if rec and rec.placed then
    inner.mb_ratio.caption = { "mb-gui.ratio", rec.n, rec.m }
  else
    inner.mb_ratio.caption = { "mb-gui.idle" }
  end
end

-- Shows the current settings of group `id` in every open GUI on one of its blocks.
---@param id integer
local function refresh_open(id)
  local st = state()
  for pi, block in pairs(st.open) do
    local player = game.get_player(pi)
    local frame = player and player.valid and player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
    if frame and group_of(block) == id then
      fill(frame, id)
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
  refresh_open(id)
  return true
end

-- Copies the settings of `source`'s group to `destination`'s group (both blocks). Returns true
-- when a setting changed.
---@param source LuaEntity
---@param destination LuaEntity
---@param player_index integer?
---@return boolean
function gui.paste(source, destination, player_index)
  local from, to = group_of(source), group_of(destination)
  if not (from and to) or from == to then
    return false
  end
  return gui.set(to, groups.settings(from), player_index)
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
        n = n + 1
      end
    end
  end
  return n
end

-- Whether `player`'s permission group allows `action` (defines.input_action); no group allows
-- everything (M5).
---@param player LuaPlayer
---@param action defines.input_action
---@return boolean
local function allowed(player, action)
  local pg = player.permission_group
  return pg == nil or pg.allows_action(action)
end

-- The one rule for opening a block's settings and for pasting settings onto it (M2): a block of
-- the player's force that the player can reach, or any such block in remote view (2.x opens
-- entity GUIs and pastes settings from the map).
---@param player LuaPlayer
---@param e LuaEntity?
---@return boolean
function gui.can_use(player, e)
  if not is_block(e) then
    return false
  end
  ---@cast e LuaEntity
  return e.force.index == player.force.index
    and (player.controller_type == defines.controllers.remote or player.can_reach_entity(e))
end

-- Closes the settings GUI of `player` (if open).
---@param player LuaPlayer
function gui.close(player)
  state().open[player.index] = nil
  local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
  if frame then
    frame.destroy()
  end
end

-- Opens the settings GUI of block `block` for `player`: a frame with the standard draggable
-- title bar and close button (M1), the ratio and the two checkboxes.
---@param player LuaPlayer
---@param block LuaEntity
function gui.open(player, block)
  local id = group_of(block)
  if not id then
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
  fill(frame, id)
  frame.auto_center = true
  state().open[player.index] = block
  player.opened = frame
end

-- Re-checks the open settings GUI of `player` (M3): closed when its block is gone, out of reach
-- (gui.can_use) or no longer allowed, refreshed otherwise.
---@param player LuaPlayer
function gui.check(player)
  local block = state().open[player.index]
  if block == nil then
    return
  end
  local id = group_of(block)
  if not (id and gui.can_use(player, block) and allowed(player, defines.input_action.open_gui)) then
    gui.close(player)
    return
  end
  local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
  if frame then
    fill(frame, id)
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

-- The copy-entity-settings control: remembers the block under the cursor (anything else clears
-- it). Its settings are read when they are pasted (M4), as vanilla pastes the source's current
-- settings.
---@param player LuaPlayer
function gui.copy_input(player)
  local e = player.selected
  local st = state()
  if group_of(e) and allowed(player, defines.input_action.copy_entity_settings) then
    st.copy[player.index] = e
  else
    st.copy[player.index] = nil
  end
end

-- The paste-entity-settings control: gives the block under the cursor the current settings of
-- the copied block; nothing when that block is gone (as vanilla). Returns true when a setting
-- changed.
---@param player LuaPlayer
---@return boolean
function gui.paste_input(player)
  local src = state().copy[player.index]
  local dst = player.selected
  if not (src and group_of(src) and gui.can_use(player, dst) and allowed(player, defines.input_action.paste_entity_settings)) then
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
  if key ~= "lanes" and key ~= "recirc" then
    return false
  end
  local block = state().open[player.index]
  local id = group_of(block)
  if not id or not gui.can_use(player, block) or not allowed(player, defines.input_action.open_gui) then
    gui.close(player) -- the block is gone or out of reach
    return false
  end
  local changed = gui.set(id, { [key] = el.state }, player.index)
  if not changed then
    local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
    if frame then
      fill(frame, id)
    end
  end
  return changed
end

-- Forgets everything kept for player `index` (on_player_removed, M1): its open block and its
-- copied block, so a new player who gets the index inherits nothing.
---@param index integer
function gui.forget(index)
  local st = state()
  st.open[index] = nil
  st.copy[index] = nil
end

-- After every balancer flush (balancer.after_flush): a group whose rebuild was refused keeps its
-- old network, so its settings go back to those of that network (M6: the checkboxes show what
-- the balancer does; the refusal message says the old balancer and its settings are kept), and
-- every open GUI is checked again (M3: its block may be gone, or its ratio changed).
---@param refreshed integer[]
function gui.after_flush(refreshed)
  for _, gid in ipairs(refreshed) do
    local rec = balancer.get(gid)
    if rec and rec.placed and groups.get(gid) then
      for _, r in ipairs(rec.refused) do
        if r.reason == "too-many-items" or r.reason == "rebuild-failed" then
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
    local player = game.get_player(pi)
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
  local player = game.get_player(event.player_index)
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

-- on_player_left_game: the frame would stay on screen after a reload (M1).
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
-- reach closes (M3). Only a player with an open frame does any work.
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
