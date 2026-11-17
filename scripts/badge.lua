-- The filter icons drawn on a block in alt mode, as an inserter shows its filters: the items of
-- the block's filter (scripts/filters.lua) while "Use filters" is on, each crossed out with the
-- vanilla blacklist mark for a blacklist; per lane, slot 1 on the left and slot 2 on the right.
-- Render objects attached to the block (they go with it); redrawn only when the filter changes or
-- the block is built, never per tick. The objects are kept on the block record (scripts/groups.lua).
local filters = require("scripts.filters")

local badge = {}

-- The block's sprite stands above its tile's centre: the icons are drawn this much higher.
local LIFT = -0.15

-- Icon centres (tile offsets from the block's centre) and scale for `n` icons.
local function layout(n)
  if n == 1 then
    return { { 0, 0 } }, 0.5
  elseif n == 2 then
    return { { -0.24, 0 }, { 0.24, 0 } }, 0.42
  end
  local list = {}
  local s = 0.28
  local rows = { math.min(n, 3), n - math.min(n, 3) }
  for r = 1, 2 do
    local count = rows[r]
    for k = 1, count do
      local x = (k - (count + 1) / 2) * s
      local y = (n > 3) and ((r == 1) and -s / 2 or s / 2) or 0
      list[#list + 1] = { x, y }
    end
  end
  return list, 0.26
end

-- Draws the icons of filter record `f` on block `e` (nothing when it filters nothing). Returns
-- the render objects.
---@param e LuaEntity
---@param f table?
---@return LuaRenderObject[]
function badge.draw(e, f)
  f = filters.normalize(f)
  local out = {}
  if not (f and f.use and e.valid) then
    return out
  end
  local items = {}
  local count = f.lanes and 2 or filters.SLOTS
  for i = 1, count do
    local v = f.items[i]
    if v ~= "" and prototypes.item[v] then
      items[#items + 1] = v
    end
  end
  if #items == 0 then
    return out
  end
  local spots, scale = layout(#items)
  if f.lanes then
    spots, scale = { { -0.24, 0 }, { 0.24, 0 } }, 0.42
    if f.items[1] == "" or not prototypes.item[f.items[1]] then
      spots = { { 0.24, 0 } } -- the right lane only
    elseif #items == 1 then
      spots = { { -0.24, 0 } } -- the left lane only
    end
  end
  for k, name in ipairs(items) do
    local spot = spots[k] --[[@as {[1]: number, [2]: number}]]
    local target = { entity = e, offset = { spot[1], spot[2] + LIFT } }
    -- the dark backdrop vanilla draws behind alt-mode icons, a layer below the icon
    out[#out + 1] = rendering.draw_sprite({ sprite = "utility/entity_info_dark_background", target = target,
      surface = e.surface, x_scale = scale * 1.5, y_scale = scale * 1.5, only_in_alt_mode = true,
      render_layer = "entity-info-icon" })
    out[#out + 1] = rendering.draw_sprite({ sprite = "item/" .. name, target = target, surface = e.surface,
      x_scale = scale, y_scale = scale, only_in_alt_mode = true, render_layer = "entity-info-icon-above" })
    if f.exclude and not f.lanes then
      out[#out + 1] = rendering.draw_sprite({ sprite = "utility/filter_blacklist", target = target, surface = e.surface,
        x_scale = scale, y_scale = scale, only_in_alt_mode = true, render_layer = "entity-info-icon-above" })
    end
  end
  return out
end

-- Destroys render objects `list`.
---@param list LuaRenderObject[]?
function badge.clear(list)
  for _, o in ipairs(list or {}) do
    if o.valid then
      o.destroy()
    end
  end
end

return badge
