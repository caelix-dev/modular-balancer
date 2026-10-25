-- Sets the graphics variation of every balancer block on a surface from its neighbourhood, the
-- way a build-time hook would (prototypes/blocks.lua, Plan 3 Task 4 candidates):
--   variation = 1 + n + 3 e + 9 s + 27 w, side state 0 open, 1 block of the same tier and force,
--   2 port (an edge `mb-edge-*` on that side running along the axis to the block).
-- Paste as the body of an fdev `exec_lua` call. Returns the number of blocks set.
local surface = game.surfaces[1]
local D = defines.direction
local SIDES = {
  { dx = 0, dy = -1, w = 1, axis = { [D.north] = true, [D.south] = true } },
  { dx = 1, dy = 0, w = 3, axis = { [D.east] = true, [D.west] = true } },
  { dx = 0, dy = 1, w = 9, axis = { [D.north] = true, [D.south] = true } },
  { dx = -1, dy = 0, w = 27, axis = { [D.east] = true, [D.west] = true } },
}
local count = 0
for _, b in pairs(surface.find_entities_filtered({ type = "simple-entity-with-owner" })) do
  if b.name:find("^mb%-balancer%-") then
    local v = 1
    local x, y = b.position.x or 0, b.position.y or 0
    for _, side in ipairs(SIDES) do
      local p = { x + side.dx, y + side.dy }
      local state = 0
      local other = surface.find_entity(b.name, p)
      if other and other.force == b.force then
        state = 1
      else
        for _, e in pairs(surface.find_entities_filtered({ position = p, type = "linked-belt" })) do
          if e.name:find("^mb%-edge%-") and side.axis[e.direction] then
            state = 2
          end
        end
      end
      v = v + state * side.w
    end
    b.graphics_variation = v
    count = count + 1
  end
end
return count
