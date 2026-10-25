-- The hidden-surface region allocator (scripts/surface.lua surface.alloc / surface.free) under
-- churn (Plan 2 final review M9: regions reused or fragmented over many builds and removals).
local surface = require("scripts.surface")

---@return mb.Regions
local function fresh()
  return { cursor_x = 0, cursor_y = 0, row_h = 0, used = {}, free = {} }
end

-- Deterministic pseudo-random numbers (an LCG), the same on every run.
---@return fun(n: integer): integer
local function lcg(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
end

local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- Every used and free region is disjoint from every other.
local function check_disjoint(r, what)
  local all = {}
  for _, u in pairs(r.used) do
    all[#all + 1] = u
  end
  for _, f in ipairs(r.free) do
    all[#all + 1] = f
  end
  for i = 1, #all do
    for j = i + 1, #all do
      assert(not overlaps(all[i], all[j]), what .. ": regions overlap: " .. all[i].x .. "," .. all[i].y .. " and " .. all[j].x .. "," .. all[j].y)
    end
  end
end

-- Network footprints in tiles (builder.size of 1:1 up to 64:65 and 128:128, roughly).
local SIZES = { { 9, 3 }, { 25, 18 }, { 41, 30 }, { 133, 99 }, { 277, 204 }, { 441, 330 }, { 117, 87 } }

-- `steps` random builds and removals with at most `live_max` networks at a time. Returns the
-- highest row extent (tiles of surface depth used) and the peak live area.
local function churn(r, seed, steps, live_max, check)
  local rand = lcg(seed)
  local live = {}
  ---@type number, number
  local high, peak = 0, 0
  for step = 1, steps do
    if #live > 0 and (#live >= live_max or rand(3) == 1) then
      local i = rand(#live)
      surface.free(r, table.remove(live, i))
    else
      local s = SIZES[rand(#SIZES)] or SIZES[1]
      local w, h = s[1] --[[@as integer]], s[2] --[[@as integer]]
      local reg = surface.alloc(r, w, h)
      assert(reg.w >= w + 1 and reg.h >= h + 1, "region too small")
      live[#live + 1] = { x = reg.x, y = reg.y }
    end
    ---@type number
    local area = 0
    for _, u in pairs(r.used) do
      area = area + u.w * u.h
    end
    peak = math.max(peak, area)
    high = math.max(high, r.cursor_y + r.row_h)
    if check and step % 50 == 0 then
      check_disjoint(r, "step " .. step)
    end
  end
  return high, peak, live
end

return {
  allocator_regions_never_overlap = function()
    local r = fresh()
    churn(r, 7, 600, 25, true)
    check_disjoint(r, "end")
  end,

  allocator_freed_space_joins_back = function()
    local r = fresh()
    local _, _, live = churn(r, 11, 400, 20, false)
    for _, o in ipairs(live) do
      surface.free(r, o)
    end
    assert(next(r.used) == nil, "regions still in use")
    -- everything freed: the free list joins back into few pieces, and one request as large as a
    -- whole row-height block fits again without moving the cursor
    local cursor = r.cursor_y
    local big = surface.alloc(r, 441, 330)
    assert(r.cursor_y == cursor, "a large request after freeing everything went to a new row")
    assert(big.y < r.cursor_y + r.row_h, "a large request was placed beyond the used rows")
  end,

  allocator_churn_stays_bounded = function()
    local r = fresh()
    local high, peak = churn(r, 3, 3000, 30, false)
    -- the surface depth used, in rows of 2 048 tiles, against the most area ever live at once
    local used_area = high * 2048
    local ratio = used_area / peak
    print(string.format("  allocator churn: 3000 steps, peak live %d tiles^2, depth %d tiles (%.2fx peak)", peak, high, ratio))
    assert(ratio < 6, "the allocator used " .. ratio .. "x the peak live area")
  end,
}
