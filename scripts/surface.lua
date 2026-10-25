-- The hidden surface that holds every balancing network, and a region allocator on it.
--
-- storage.surface_index  index of the surface "mb-hidden"
-- storage.regions        { cursor_x, cursor_y, row_h, used = { [key] = Region }, free = { Region } }
--                        Region = { x, y, w, h } in tiles; key = "x,y" of its origin
--
-- Regions are whole chunks plus a free chunk-aligned gap, laid out in rows of ROW_WIDTH tiles.
-- A released region goes on the free list, joined with free neighbours; a request takes the
-- smallest free region that fits and leaves the rest of it free (surface.alloc, surface.free).
-- All of this runs only when a network is built or removed.
local surface = {}

local NAME = "mb-hidden"
local CHUNK = 32
local ROW_WIDTH = 64 * CHUNK

---@class mb.Region
---@field x integer
---@field y integer
---@field w integer
---@field h integer

---@class mb.Regions
---@field cursor_x integer
---@field cursor_y integer
---@field row_h integer
---@field used table<string, mb.Region>
---@field free mb.Region[]

---@return mb.Regions
local function regions()
  storage.regions = storage.regions or { cursor_x = 0, cursor_y = 0, row_h = 0, used = {}, free = {} }
  return storage.regions
end

local function key(x, y)
  return x .. "," .. y
end

-- Rounds up to whole chunks, with at least one free tile after the content.
---@param n integer
---@return integer
local function chunks(n)
  return math.ceil((n + 1) / CHUNK) * CHUNK --[[@as integer]]
end

---@param s LuaSurface
local function hide_for_all(s)
  for _, force in pairs(game.forces) do
    force.set_surface_hidden(s, true)
  end
end

---@return LuaSurface
function surface.get()
  local s = storage.surface_index and game.get_surface(storage.surface_index)
  if s and s.valid then
    return s
  end
  s = game.get_surface(NAME)
  if not s then
    -- a new surface (first use, or the old one was deleted): every region is free
    storage.regions = nil
  end
  s = s
    or game.create_surface(NAME, {
      default_enable_all_autoplace_controls = false,
      autoplace_settings = {
        entity = { treat_missing_as_default = false, settings = {} },
        decorative = { treat_missing_as_default = false, settings = {} },
        tile = { treat_missing_as_default = false, settings = {} },
      },
      no_enemies_mode = true,
      peaceful_mode = true,
    })
  s.generate_with_lab_tiles = true
  s.always_day = true
  s.show_clouds = false
  hide_for_all(s)
  storage.surface_index = s.index
  return s
end

-- New forces must not see the hidden surface either (control.lua: on_force_created).
---@param force LuaForce
function surface.on_force_created(force)
  local s = storage.surface_index and game.get_surface(storage.surface_index)
  if s and s.valid then
    force.set_surface_hidden(s, true)
  end
end

---@param w integer
---@param h integer
---@return {x: integer, y: integer} origin top-left tile corner of a free w x h rectangle (chunks generated)
function surface.reserve(w, h)
  -- the surface first: making a new one (the old one was deleted) resets the regions
  local s = surface.get()
  local r = regions()
  local region = surface.alloc(r, w, h)
  r.used[key(region.x, region.y)] = region

  for cx = region.x / CHUNK, (region.x + region.w) / CHUNK - 1 do
    for cy = region.y / CHUNK, (region.y + region.h) / CHUNK - 1 do
      if not s.is_chunk_generated({ cx, cy }) then
        s.request_to_generate_chunks({ cx * CHUNK + CHUNK / 2, cy * CHUNK + CHUNK / 2 }, 0)
      end
    end
  end
  s.force_generate_chunk_requests()
  return { x = region.x, y = region.y }
end

-- Frees a region returned by reserve. The caller has destroyed its entities.
---@param origin {x: integer, y: integer}
function surface.release(origin)
  surface.free(regions(), origin)
end

-- The allocator itself, pure (tests/unit/allocator_test.lua): takes a region of at least w x h
-- tiles (rounded up to whole chunks plus a gap) from `r`. Best fit: the free region of the least
-- area that holds it, split so the request takes its top-left corner and the rest (the strip to
-- its right, then the strip below) stays free; else a new region at the cursor.
---@param r mb.Regions
---@param w integer
---@param h integer
---@return mb.Region
function surface.alloc(r, w, h)
  local rw, rh = chunks(w), chunks(h)
  ---@type mb.Region?, integer?
  local best, best_i
  for i, f in ipairs(r.free) do
    if f.w >= rw and f.h >= rh then
      if not best or f.w * f.h < best.w * best.h or (f.w * f.h == best.w * best.h and (f.y < best.y or (f.y == best.y and f.x < best.x))) then
        best, best_i = f, i
      end
    end
  end
  ---@type mb.Region
  local region
  if best then
    table.remove(r.free, best_i)
    region = { x = best.x, y = best.y, w = rw, h = rh }
    if best.w > rw then
      r.free[#r.free + 1] = { x = best.x + rw, y = best.y, w = best.w - rw, h = rh }
    end
    if best.h > rh then
      r.free[#r.free + 1] = { x = best.x, y = best.y + rh, w = best.w, h = best.h - rh }
    end
  else
    if r.cursor_x > 0 and r.cursor_x + rw > ROW_WIDTH then
      r.cursor_x, r.cursor_y, r.row_h = 0, r.cursor_y + r.row_h, 0
    end
    region = { x = r.cursor_x, y = r.cursor_y, w = rw, h = rh }
    r.cursor_x = r.cursor_x + rw
    r.row_h = math.max(r.row_h, rh)
  end
  r.used[key(region.x, region.y)] = region
  return region
end

-- Gives the region at `origin` back to `r`, joined with free neighbours that share a whole edge
-- with it (repeatedly), so freed space does not stay cut into pieces.
---@param r mb.Regions
---@param origin {x: integer, y: integer}
function surface.free(r, origin)
  local k = key(origin.x, origin.y)
  local region = r.used[k]
  if not region then
    error("surface.release: no region at " .. k)
  end
  r.used[k] = nil
  local cur = { x = region.x, y = region.y, w = region.w, h = region.h }
  local merged = true
  while merged do
    merged = false
    for i, f in ipairs(r.free) do
      local join
      if f.y == cur.y and f.h == cur.h and (f.x + f.w == cur.x or cur.x + cur.w == f.x) then
        join = { x = math.min(f.x, cur.x), y = cur.y, w = f.w + cur.w, h = cur.h }
      elseif f.x == cur.x and f.w == cur.w and (f.y + f.h == cur.y or cur.y + cur.h == f.y) then
        join = { x = cur.x, y = math.min(f.y, cur.y), w = cur.w, h = f.h + cur.h }
      end
      if join then
        table.remove(r.free, i)
        cur = join
        merged = true
        break
      end
    end
  end
  r.free[#r.free + 1] = cur
end

return surface
