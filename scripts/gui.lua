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
--                closes it.
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
--   copy = { [player index] = { lanes: boolean, recirc: boolean } },   settings copied by the
--                                                              copy-entity-settings control
-- }
-- Everything runs in events, so all players compute the same (multiplayer-safe); nothing is done
-- in on_load.
local groups = require("scripts.groups")
local balancer = require("scripts.balancer")

local gui = {}

local FRAME = "mb_settings"
local TAG_LANES, TAG_RECIRC = "mb_lanes", "mb_recirc"

local function state()
  storage.mb_gui = storage.mb_gui or { open = {}, copy = {} }
  return storage.mb_gui
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

-- Closes the settings GUI of `player` (if open).
---@param player LuaPlayer
function gui.close(player)
  state().open[player.index] = nil
  local frame = player.gui.screen[FRAME] --[[@as LuaGuiElement?]]
  if frame then
    frame.destroy()
  end
end

-- Opens the settings GUI of block `block` for `player`.
---@param player LuaPlayer
---@param block LuaEntity
function gui.open(player, block)
  local id = group_of(block)
  if not id then
    return
  end
  gui.close(player)
  local frame = player.gui.screen.add({ type = "frame", name = FRAME, caption = { "mb-gui.title" }, direction = "vertical" })
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

-- mb-open-gui (the open-gui control): opens the GUI of the block under the cursor.
---@param event EventData.CustomInputEvent
function gui.on_open_input(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then
    return
  end
  local e = player.selected
  if not is_block(e) then
    return
  end
  ---@cast e LuaEntity
  if not player.is_cursor_empty() or e.force.index ~= player.force.index or not player.can_reach_entity(e) then
    return
  end
  gui.open(player, e)
end

-- mb-copy-settings (copy-entity-settings): remembers the settings of the block under the cursor
-- (anything else clears them).
---@param event EventData.CustomInputEvent
function gui.on_copy_input(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then
    return
  end
  local id = group_of(player.selected)
  state().copy[event.player_index] = id and groups.settings(id) or nil
end

-- mb-paste-settings (paste-entity-settings): gives the block under the cursor the copied
-- settings.
---@param event EventData.CustomInputEvent
function gui.on_paste_input(event)
  local player = game.get_player(event.player_index)
  local s = state().copy[event.player_index]
  if not (s and player and player.valid) then
    return
  end
  local e = player.selected
  local id = group_of(e)
  ---@cast e LuaEntity
  if id and e.force.index == player.force.index then
    gui.set(id, s, event.player_index)
  end
end

---@param event EventData.on_gui_checked_state_changed
function gui.on_checked(event)
  local el = event.element
  local key = el.valid and el.tags and el.tags.mb_setting
  if key ~= "lanes" and key ~= "recirc" then
    return
  end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then
    return
  end
  local block = state().open[event.player_index]
  local id = group_of(block)
  if not id then
    gui.close(player) -- the block is gone
    return
  end
  gui.set(id, { [key] = el.state }, event.player_index)
end

---@param event EventData.on_gui_closed
function gui.on_closed(event)
  local el = event.element
  if el and el.valid and el.name == FRAME then
    local player = game.get_player(event.player_index)
    if player and player.valid then
      gui.close(player)
    end
  end
end

return gui
