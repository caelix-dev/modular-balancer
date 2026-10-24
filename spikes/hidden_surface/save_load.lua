-- Spike S2 (throwaway): the F2 save/load check as a remote interface, so it can be rerun on an
-- MCP fdev server instance (factorio-test in portal_mods, so `mb-spikes` is on):
--   exec_lua: return remote.call("mb-spike-s2", "build")   -- once, on a fresh map
--   exec_lua: return remote.call("mb-spike-s2", "count")   -- before the save
--   exec_lua: game.server_save("f2")                         -- then server_stop
--   server_start with save = E:\factorio-dev\instances\<name>\saves\f2.zip
--   exec_lua: return remote.call("mb-spike-s2", "count")   -- must match; run_ticks; count again
-- Loaded from control.lua only with `mb-spikes`. Results: docs/feasibility/f2-save-load.txt.

local D = defines.direction
local SURFACE = "mb-spike-s2-hidden"
local AREA = { { -1, -1 }, { 12, 8 } }
local LINES = { defines.transport_line.left_line, defines.transport_line.right_line }

local function belt_name()
  return script.active_mods["space-age"] and "turbo-transport-belt" or "express-transport-belt"
end

local function ce(s, t)
  t.force = "player"
  return assert(s.create_entity(t), "could not create " .. t.name)
end

-- Builds, on nauvis and a hidden surface:
--   a ring: nauvis output linked belt (0.5, 0.5) -> 4 belts -> nauvis input linked belt
--     (5.5, 0.5) => hidden output linked belt -> 4 belts -> hidden input linked belt => back;
--     32 plates on the nauvis belts;
--   a belt port: hidden belt row 4 -> hidden input linked belt (5.5, 4.5) => nauvis output
--     linked belt (5.5, 4.5) facing west under an mb-spike-block (a dead end), with plates
--     on both, and a disabled inserter east of the block whose pickup_target is the port.
local function build()
  local n = game.surfaces.nauvis
  n.request_to_generate_chunks({ 0, 0 }, 1)
  n.force_generate_chunk_requests()
  for _, e in ipairs(n.find_entities_filtered({ area = AREA })) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = -1, 11 do
    for y = -1, 7 do tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } } end
  end
  n.set_tiles(tiles)
  local h = game.create_surface(SURFACE, { width = 64, height = 64 })
  h.generate_with_lab_tiles = true
  h.request_to_generate_chunks({ 0, 0 }, 1)
  h.force_generate_chunk_requests()
  game.forces.player.set_surface_hidden(h, true)
  local belt = belt_name()
  local function row(s, y)
    local head = ce(s, { name = "mb-spike-lb", position = { 0.5, y }, direction = D.east, type = "output" })
    for x = 1, 4 do ce(s, { name = belt, position = { x + 0.5, y }, direction = D.east }) end
    local tail = ce(s, { name = "mb-spike-lb", position = { 5.5, y }, direction = D.east, type = "input" })
    return head, tail
  end
  local nhead, ntail = row(n, 0.5)
  local hhead, htail = row(h, 0.5)
  ntail.connect_linked_belts(hhead)
  htail.connect_linked_belts(nhead)
  for x = 1, 4 do
    local b = assert(n.find_entity(belt, { x + 0.5, 0.5 }), "ring belt missing")
    for _, li in ipairs(LINES) do
      for p = 0, 0.75, 0.25 do b.get_transport_line(li).insert_at(p, { name = "iron-plate", count = 1 }) end
    end
  end
  -- belt port
  for x = 1, 4 do ce(h, { name = belt, position = { x + 0.5, 4.5 }, direction = D.east }) end
  local hin = ce(h, { name = "mb-spike-lb", position = { 5.5, 4.5 }, direction = D.east, type = "input" })
  ce(n, { name = "mb-spike-block", position = { 5.5, 4.5 } })
  local port = ce(n, { name = "mb-spike-lb", position = { 5.5, 4.5 }, direction = D.west, type = "output" })
  hin.connect_linked_belts(port)
  for x = 1, 4 do
    local b = assert(h.find_entity(belt, { x + 0.5, 4.5 }), "port belt missing")
    b.get_transport_line(LINES[1]).insert_at(0.5, { name = "copper-cable", count = 1 })
    b.get_transport_line(LINES[2]).insert_at(0.5, { name = "iron-plate", count = 1 })
  end
  local ins = ce(n, { name = "mb-spike-inserter", position = { 6.5, 4.5 }, direction = D.west })
  ins.disabled_by_script = true
  ins.pickup_target = port
  ce(n, { name = "steel-chest", position = { 7.5, 4.5 } })
  return { built = true, belt = belt }
end

-- Item counts per surface and row, the links, the hidden flag and the inserter's target.
local function count()
  local out = { tick = game.tick, hidden_for_player = game.forces.player.get_surface_hidden(SURFACE) } ---@type table<string, any>
  for _, s in ipairs({ game.surfaces.nauvis, game.surfaces[SURFACE] }) do
    for _, y in ipairs({ 0.5, 4.5 }) do
      local total, links = 0, {}
      local found = s.find_entities_filtered({
        area = { { -1, y - 0.5 }, { 8, y + 0.5 } }, type = { "linked-belt", "transport-belt" },
      })
      for _, e in ipairs(found) do
        for _, li in ipairs(LINES) do total = total + e.get_transport_line(li).get_item_count() end
        if e.type == "linked-belt" then
          local nb = e.linked_belt_neighbour
          links[#links + 1] = string.format("%s@%.1f->%s@%.1f", e.linked_belt_type, e.position.x,
            nb and nb.surface.name or "none", nb and nb.position.x or -1)
        end
      end
      table.sort(links)
      out[s.name .. "@" .. y] = { items = total, links = table.concat(links, " ") }
    end
  end
  local ins = game.surfaces.nauvis.find_entity("mb-spike-inserter", { 6.5, 4.5 })
  out.port_pickup_target = ins and ins.pickup_target and ins.pickup_target.name or "nil"
  return out
end

remote.add_interface("mb-spike-s2", { build = build, count = count })
