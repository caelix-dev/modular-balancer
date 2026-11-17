-- Connected look of the balancer blocks. Shared by the prototype stage
-- (prototypes/blocks.lua: one graphics variation per neighbourhood) and the control stage
-- (scripts/balancer.lua: sets each block's variation when its group is refreshed).
--
-- A neighbourhood is a mask of the same group's blocks around a block: side bits N=1 E=2 S=4
-- W=8 and corner bits NE=16 SE=32 SW=64 NW=128, a corner bit kept only when both of its sides are
-- set (it only decides the inner corner of an L). That leaves 47 masks; the variation of a mask
-- is its position in `look.masks()` (ascending), so a lone block is variation 1. The sprite sheets
-- (graphics/entity/balancer/, rendered by tools/render/) use the same order.
local look = {}

local N, E, S, W, NE, SE, SW, NW = 1, 2, 4, 8, 16, 32, 64, 128

---@param m integer
---@return integer
local function canonical(m)
  local c = m % 16
  local function has(bit)
    return math.floor(m / bit) % 2 == 1
  end
  if has(N) and has(E) and has(NE) then
    c = c + NE
  end
  if has(E) and has(S) and has(SE) then
    c = c + SE
  end
  if has(S) and has(W) and has(SW) then
    c = c + SW
  end
  if has(W) and has(N) and has(NW) then
    c = c + NW
  end
  return c
end
look.canonical = canonical

---@type integer[]
local list = {}
---@type table<integer, integer>
local index = {}
for m = 0, 255 do
  if canonical(m) == m then
    list[#list + 1] = m
    index[m] = #list
  end
end

---@return integer[]
function look.masks()
  return list
end

-- The graphics variation (1..47) of a block whose neighbours are given by `mask` (any of 0..255).
---@param mask integer
---@return integer
function look.variation(mask)
  return index[canonical(mask)] or 1
end

-- Neighbour offsets and their bits.
look.OFFSETS = {
  { 0, -1, N }, { 1, 0, E }, { 0, 1, S }, { -1, 0, W },
  { 1, -1, NE }, { 1, 1, SE }, { -1, 1, SW }, { -1, -1, NW },
}

-- Sets the graphics variation of every block of a group from the group's own tiles.
-- `blocks`: unit -> block entity; `where(unit)` -> surface index, x, y of that block's tile.
-- Writes only variations that changed.
---@param blocks table<integer, LuaEntity>
---@param where fun(unit: integer): integer?, integer?, integer?
function look.dress(blocks, where)
  local at = {}
  for u in pairs(blocks) do
    local _, x, y = where(u)
    if x and y then
      at[x .. "," .. y] = true
    end
  end
  for u, e in pairs(blocks) do
    local _, x, y = where(u)
    if x and y and e.valid then
      local m = 0
      for _, o in ipairs(look.OFFSETS) do
        if at[(x + o[1]) .. "," .. (y + o[2])] then
          m = m + o[3]
        end
      end
      local v = look.variation(m)
      if e.graphics_variation ~= v then
        e.graphics_variation = v
      end
    end
  end
end

return look
