-- Spike S1 (throwaway): several belts per 1x1 block. Runs only with the `mb-spikes` setting.
-- Results are logged with the prefix "MB-SPIKE" (factorio-current.log) and recorded in
-- docs/feasibility.md F1.

local D = defines.direction
local SA = script.active_mods["space-age"] ~= nil
local BELT = SA and "turbo-transport-belt" or "express-transport-belt"
local UNDERGROUND = SA and "turbo-underground-belt" or "express-underground-belt"
local RATE = SA and 60 or 45 -- items per second of one full belt of the measured tier
local MEASURE = 1200

local VEC = {
  [D.north] = { 0, -1 },
  [D.east] = { 1, 0 },
  [D.south] = { 0, 1 },
  [D.west] = { -1, 0 },
}
local LINES = { defines.transport_line.left_line, defines.transport_line.right_line }
local OPPOSITE = { [D.north] = D.south, [D.east] = D.west, [D.south] = D.north, [D.west] = D.east }

local surface ---@type LuaSurface
local next_row = 0

local function report(fmt, ...)
  log("MB-SPIKE " .. string.format(fmt, ...))
end

local function ce(t)
  t.force = t.force or "player"
  local e = surface.create_entity(t)
  assert(e, "could not create " .. t.name .. " at " .. serpent.line(t.position))
  return e
end

-- A fresh 40x40 area per test, far from the others.
local function origin()
  next_row = next_row + 1
  return { x = 0.5, y = next_row * 40 + 0.5 }
end

local function at(o, dx, dy)
  return { x = o.x + dx, y = o.y + dy }
end

local function step(o, dir, n)
  local v = VEC[dir]
  return at(o, v[1] * n, v[2] * n)
end

-- A straight belt of `len` tiles that ends next to the block at `o` and points into it
-- (input) or starts next to it and points away (output). Returns the positions, the tile
-- next to the block first.
local function belt_line(o, side, len, kind)
  local dir = kind == "input" and OPPOSITE[side] or side
  local tiles = {}
  for i = 1, len do
    local p = step(o, side, i)
    ce({ name = BELT, position = p, direction = dir })
    tiles[i] = p
  end
  return tiles, dir
end

-- Candidate (e): swap the player's belt tile next to the block for an edge linked belt of
-- the same direction, keeping the items that were on it. An edge line is half a tile long,
-- so a full belt tile does not fit; what does not fit goes onto `overflow` (the linked
-- partner, i.e. the network side) when given. Returns the edge and the count not placed.
local function swap_to_edge(pos, kind, overflow)
  local belt = surface.find_entity(BELT, pos)
  assert(belt, "no belt to swap at " .. serpent.line(pos))
  local dir = belt.direction
  local saved = {}
  for li, line in ipairs(LINES) do
    saved[li] = {}
    for _, it in ipairs(belt.get_transport_line(line).get_detailed_contents()) do
      saved[li][#saved[li] + 1] = {
        position = it.position,
        stack = { name = it.stack.name, count = it.stack.count, quality = it.stack.quality.name },
      }
    end
  end
  belt.destroy()
  local edge = ce({ name = "mb-spike-edge", position = pos, direction = dir, type = kind })
  if overflow then
    edge.connect_linked_belts(overflow)
  end
  local lost = 0
  for li, items in pairs(saved) do
    local line = edge.get_transport_line(LINES[li])
    for _, it in ipairs(items) do
      local placed = it.position <= line.line_length and line.insert_at(it.position, it.stack)
      if not placed and overflow then
        local oline = overflow.get_transport_line(LINES[li])
        for p = 0, oline.line_length, 0.25 do
          if oline.insert_at(p, it.stack) then
            placed = true
            break
          end
        end
      end
      if not placed then
        lost = lost + it.stack.count
      end
    end
  end
  return edge, lost
end

-- Saturated source at the far end of an input line (an infinity chest and a loader).
local function source(o, side, len)
  local dir = OPPOSITE[side]
  local chest = ce({ name = "infinity-chest", position = step(o, side, len + 2) })
  chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
  ce({ name = "mb-spike-io-loader", position = step(o, side, len + 1), direction = dir, type = "output" })
end

-- Counting sink at the far end of an output line (a loader into a steel chest).
local function sink(o, side, len)
  ce({ name = "mb-spike-io-loader", position = step(o, side, len + 1), direction = side, type = "input" })
  return ce({ name = "steel-chest", position = step(o, side, len + 2) })
end

-- Counts what the sinks receive over MEASURE ticks after `warmup` ticks; returns items/s.
local function measure(sinks, warmup, callback)
  local c0
  after_ticks(warmup, function()
    c0 = {}
    for i, s in ipairs(sinks) do c0[i] = s.get_item_count() end
    after_ticks(MEASURE, function()
      local rates = {}
      for i, s in ipairs(sinks) do
        rates[i] = (s.get_item_count() - c0[i]) * 60 / MEASURE
      end
      callback(rates)
      done()
    end)
  end)
end

describe("spike S1: several belts per block", function()
  before_all(function()
    surface = game.create_surface("mb-spike-s1", { width = 128, height = 1200 })
    surface.generate_with_lab_tiles = true
    surface.request_to_generate_chunks({ 0, 600 }, 20)
    surface.force_generate_chunk_requests()
    report("tier belt %s, full belt %d items/s", BELT, RATE)
  end)

  after_all(function()
    game.delete_surface(surface)
  end)

  -- (a) and (b): the prototype stage already refuses interfaces that do not collide (see
  -- data.lua). These tests record that the runtime refuses to stack them as well.
  test("spike_stacked_linked_belts_input_and_output_on_one_tile (refused)", function()
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local first = ce({ name = "mb-spike-lb", position = at(o, 0, 0), direction = D.east, type = "input" })
    local second = surface.create_entity({
      name = "mb-spike-lb", position = at(o, 0, 0), direction = D.east, type = "output", force = "player",
    })
    local cloned = first.clone({ position = at(o, 0, 0), surface = surface })
    local other = ce({ name = "mb-spike-lb", position = at(o, 2, 0), direction = D.east, type = "output" })
    local teleported = other.teleport(at(o, 0, 0))
    report("(a) on a tile with a linked belt: create_entity %s, clone %s, teleport %s",
      second and "placed" or "refused", cloned and "placed" or "refused", teleported and "moved" or "refused")
    assert(second == nil, "a second linked belt was placed on the same tile")
    assert(cloned == nil, "clone stacked a second linked belt")
    assert(not teleported, "teleport stacked a second linked belt")
  end)

  test("spike_stacked_loaders_input_and_output_on_one_tile (refused)", function()
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    ce({ name = "mb-spike-core", position = at(o, 0, 0) })
    local first = ce({ name = "mb-spike-ld", position = at(o, 0, 0), direction = D.east, type = "input" })
    local second = surface.create_entity({
      name = "mb-spike-ld", position = at(o, 0, 0), direction = D.east, type = "output", force = "player",
    })
    report("(b) loader container on own tile: %s; second loader on the tile: %s",
      first.loader_container and first.loader_container.name or "none", second and "placed" or "refused")
    assert(second == nil, "a second loader was placed on the same tile")
  end)

  -- (c): the block itself is a belt-connectable entity (a linked belt with side loading).
  -- It takes the west belt, but nothing can leave it to the east: a linked belt is one way.
  test("spike_block_as_belt_input_and_output_on_one_tile (no output)", function()
    async(900)
    local o = origin()
    local block = ce({ name = "mb-spike-cblock", position = at(o, 0, 0), direction = D.east, type = "input" })
    local partner = ce({ name = "mb-spike-cblock", position = at(o, 0, 10), direction = D.east, type = "output" })
    block.connect_linked_belts(partner)
    belt_line(o, D.west, 3, "input")
    source(o, D.west, 3)
    local east = belt_line(o, D.east, 3, "output")
    local east_belt = assert(surface.find_entity(BELT, east[1]), "east belt missing")
    after_ticks(600, function()
      local n = east_belt.get_transport_line(LINES[1]).get_item_count() + east_belt.get_transport_line(LINES[2]).get_item_count()
      report("(c) east belt items after 600 ticks: %d; block outputs: %d", n, #block.belt_neighbours.outputs)
      assert(n == 0, "the block fed its east belt")
      done()
    end)
  end)

  -- (e): edge interfaces on the player's belt tiles next to the block.
  test("spike_edge_input_and_output_on_one_tile", function()
    async(900)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local west = belt_line(o, D.west, 3, "input")
    local east = belt_line(o, D.east, 3, "output")
    local ein = swap_to_edge(west[1], "input")
    local eout = swap_to_edge(east[1], "output")
    ein.connect_linked_belts(eout)
    local chest = ce({ name = "infinity-chest", position = at(o, -3, -2) })
    chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, mode = "exactly" })
    local ins = ce({ name = "burner-inserter", position = at(o, -3, -1), direction = D.north })
    ins.get_fuel_inventory().insert({ name = "coal", count = 50 })
    local last = assert(surface.find_entity(BELT, east[3]), "east belt missing")
    on_tick(function(tick)
      local n = last.get_transport_line(LINES[1]).get_item_count() + last.get_transport_line(LINES[2]).get_item_count()
      if n > 0 then
        report("(e) first item on the east belt after %d ticks", tick)
        done()
        return false
      end
      if tick >= 600 then
        error("no item reached the east belt within 600 ticks")
      end
    end)
  end)

  test("spike_edge_throughput", function()
    async(3000)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local west = belt_line(o, D.west, 3, "input")
    local east = belt_line(o, D.east, 3, "output")
    local ein = swap_to_edge(west[1], "input")
    ein.connect_linked_belts((swap_to_edge(east[1], "output")))
    source(o, D.west, 3)
    local s = sink(o, D.east, 3)
    measure({ s }, 600, function(rates)
      report("(e) west->east throughput %.2f items/s (full belt %d)", rates[1], RATE)
      assert(rates[1] >= RATE * 0.99, "throughput " .. rates[1] .. " below a full belt")
    end)
  end)

  test("spike_edge_four_sides", function()
    async(3000)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local w = belt_line(o, D.west, 3, "input")
    local n = belt_line(o, D.north, 3, "input")
    local e = belt_line(o, D.east, 3, "output")
    local s = belt_line(o, D.south, 3, "output")
    local wi, ni = swap_to_edge(w[1], "input"), swap_to_edge(n[1], "input")
    local eo, so = swap_to_edge(e[1], "output"), swap_to_edge(s[1], "output")
    wi.connect_linked_belts(eo)
    ni.connect_linked_belts(so)
    source(o, D.west, 3)
    source(o, D.north, 3)
    local se, ss = sink(o, D.east, 3), sink(o, D.south, 3)
    for _, edge in ipairs({ wi, ni, eo, so }) do
      local nb = edge.belt_neighbours
      assert(#nb.inputs + #nb.outputs == 1, "edge at " .. serpent.line(edge.position) .. " has "
        .. (#nb.inputs + #nb.outputs) .. " belt neighbours")
    end
    measure({ se, ss }, 600, function(rates)
      report("(e) four sides: east %.2f, south %.2f items/s (full belt %d)", rates[1], rates[2], RATE)
      for i, r in ipairs(rates) do
        assert(r >= RATE * 0.99, "output " .. i .. " throughput " .. r .. " below a full belt")
      end
    end)
  end)

  -- Hybrid: the block tile holds one linked belt (any belt-connectable can feed it, here an
  -- underground exit); the other sides are edges.
  test("spike_hybrid_four_sides", function()
    async(3000)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local core = ce({ name = "mb-spike-lb", position = at(o, 0, 0), direction = D.east, type = "input" })
    ce({ name = UNDERGROUND, position = at(o, -1, 0), direction = D.east, type = "output" })
    ce({ name = UNDERGROUND, position = at(o, -4, 0), direction = D.east, type = "input" })
    belt_line(at(o, -4, 0), D.west, 1, "input")
    source(at(o, -4, 0), D.west, 1)
    local n = belt_line(o, D.north, 3, "input")
    local e = belt_line(o, D.east, 3, "output")
    local s = belt_line(o, D.south, 3, "output")
    local ni = swap_to_edge(n[1], "input")
    local eo, so = swap_to_edge(e[1], "output"), swap_to_edge(s[1], "output")
    core.connect_linked_belts(eo)
    ni.connect_linked_belts(so)
    source(o, D.north, 3)
    local se, ss = sink(o, D.east, 3), sink(o, D.south, 3)
    local nb = core.belt_neighbours
    report("(hybrid) block-tile linked belt: %d inputs, %d outputs", #nb.inputs, #nb.outputs)
    assert(#nb.inputs == 1 and #nb.outputs == 0, "block-tile linked belt connected to more than its feeder")
    measure({ se, ss }, 600, function(rates)
      report("(hybrid) four sides: east %.2f, south %.2f items/s (full belt %d)", rates[1], rates[2], RATE)
      for i, r in ipairs(rates) do
        assert(r >= RATE * 0.99, "output " .. i .. " throughput " .. r .. " below a full belt")
      end
    end)
  end)

  test("spike_edge_swap_keeps_items", function()
    local o = origin()
    local tiles = belt_line(o, D.west, 1, "input")
    local belt = assert(surface.find_entity(BELT, tiles[1]), "belt missing")
    -- A full tile: 4 items per lane.
    for _, line in ipairs(LINES) do
      for _, pos in ipairs({ 0.125, 0.375, 0.625, 0.875 }) do
        assert(belt.get_transport_line(line).insert_at(pos, { name = "iron-plate", count = 1 }), "setup insert")
      end
    end
    local partner = ce({ name = "mb-spike-edge", position = at(o, 0, 5), direction = D.east, type = "output" })
    local edge, lost = swap_to_edge(tiles[1], "input", partner)
    local kept, moved = {}, {}
    for i, line in ipairs(LINES) do
      kept[i] = edge.get_transport_line(line).get_item_count("iron-plate")
      moved[i] = partner.get_transport_line(line).get_item_count("iron-plate")
    end
    report("(e) swap of a full belt tile: %d + %d stay on the edge (line length %.3f), %d + %d moved to the partner, %d lost",
      kept[1], kept[2], edge.get_transport_line(LINES[1]).line_length, moved[1], moved[2], lost)
    assert(kept[1] + kept[2] + moved[1] + moved[2] == 8, "items unaccounted for")
    assert(lost == 0, lost .. " items were lost")
  end)
end)
