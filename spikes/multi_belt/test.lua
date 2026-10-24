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

-- Items on both lines of a belt-connectable entity.
local function items_on(e)
  return e.get_transport_line(LINES[1]).get_item_count() + e.get_transport_line(LINES[2]).get_item_count()
end

-- Fills both lines of a belt-connectable entity as densely as insert_at allows; returns the count.
local function fill(e, item)
  local n = 0
  for _, li in ipairs(LINES) do
    local line = e.get_transport_line(li)
    for p = 0, line.line_length, 0.03125 do
      if line.insert_at(p, { name = item or "iron-plate", count = 1 }) then n = n + 1 end
    end
  end
  return n
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
-- the same direction, keeping the items that were on it (belt stacks included).
-- An edge line is half a tile long, so a full belt tile does not fit. The rule measured here:
--   1. an item goes onto the edge at its own position if that is on the edge and free;
--   2. else onto the linked partner `partner` (the network side), if given and it has room;
--   3. else it is force-inserted at the front of the edge (squashed, never dropped).
-- Returns the edge and { edge = n, partner = n, forced = n } item counts.
local function swap_to_edge(pos, kind, partner, name)
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
  name = name or (kind == "input" and "mb-spike-edge" or "mb-spike-edge-out")
  local edge = ce({ name = name, position = pos, direction = dir, type = kind })
  if partner then
    edge.connect_linked_belts(partner)
  end
  local stats = { edge = 0, partner = 0, forced = 0 }
  for li, items in pairs(saved) do
    local line = edge.get_transport_line(LINES[li])
    for _, it in ipairs(items) do
      local n = it.stack.count
      if it.position <= line.line_length and line.insert_at(it.position, it.stack, n) then
        stats.edge = stats.edge + n
      else
        local placed = false
        if partner then
          local pline = partner.get_transport_line(LINES[li])
          for p = 0, pline.line_length, 0.125 do
            if pline.insert_at(p, it.stack, n) then
              placed = true
              break
            end
          end
        end
        if placed then
          stats.partner = stats.partner + n
        else
          line.force_insert_at(line.line_length, it.stack, n)
          stats.forced = stats.forced + n
        end
      end
    end
  end
  return edge, stats
end

-- Saturated source at the far end of an input line (an infinity chest and a loader).
local function source(o, side, len, item)
  local dir = OPPOSITE[side]
  local chest = ce({ name = "infinity-chest", position = step(o, side, len + 2) })
  chest.set_infinity_container_filter(1, { name = item or "iron-plate", count = 100, mode = "exactly" })
  ce({ name = "mb-spike-io-loader", position = step(o, side, len + 1), direction = dir, type = "output" })
end

-- Counting sink at the far end of an output line (a loader into a steel chest).
local function sink(o, side, len)
  ce({ name = "mb-spike-io-loader", position = step(o, side, len + 1), direction = side, type = "input" })
  return ce({ name = "steel-chest", position = step(o, side, len + 2) })
end

-- A stand-in for the hidden network between two edges: output-type linked belt, `len` belts,
-- input-type linked belt, built eastward from `p`. Returns the two linked belts.
local function hidden_chain(p, len)
  local head = ce({ name = "mb-spike-lb", position = p, direction = D.east, type = "output" })
  for i = 1, len do
    ce({ name = BELT, position = at(p, i, 0), direction = D.east })
  end
  local tail = ce({ name = "mb-spike-lb", position = at(p, len + 1, 0), direction = D.east, type = "input" })
  return head, tail
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
    surface = game.create_surface("mb-spike-s1", { width = 128, height = 1600 })
    surface.generate_with_lab_tiles = true
    surface.request_to_generate_chunks({ 0, 800 }, 26)
    surface.force_generate_chunk_requests()
    report("tier belt %s, full belt %d items/s", BELT, RATE)
  end)

  after_all(function()
    game.delete_surface(surface)
  end)

  -- (a) and (b): the prototype stage refuses interfaces that do not collide (data.lua
  -- variants, repro-load-errors.sh). These tests record that the runtime refuses to stack
  -- them on one tile as well.
  test("spike_stacked_linked_belts_refused", function()
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

  test("spike_stacked_loaders_refused", function()
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    ce({ name = "mb-spike-core", position = at(o, 0, 0) })
    ce({ name = "mb-spike-ld", position = at(o, 0, 0), direction = D.east, type = "input" })
    local second = surface.create_entity({
      name = "mb-spike-ld", position = at(o, 0, 0), direction = D.east, type = "output", force = "player",
    })
    report("(b) second loader on a loader tile: %s", second and "placed" or "refused")
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
      local n = items_on(east_belt)
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
      if items_on(last) > 0 then
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

  -- The intent's 1x8 row: 8 input edges on the west face, 3 output edges on the east face.
  -- Inputs 1..3 are linked straight to the 3 outputs (the network is Task 3-5); inputs 4..8
  -- back up. Checks the geometry (no edge connects to a neighbouring edge) and throughput.
  test("spike_edge_row_1x8_eight_in_three_out", function()
    async(3000)
    local o = origin()
    local ins, outs, sinks = {}, {}, {}
    for i = 0, 7 do
      local b = at(o, 0, i)
      ce({ name = "mb-spike-block", position = b })
      local w = belt_line(b, D.west, 2, "input")
      source(b, D.west, 2)
      ins[#ins + 1] = swap_to_edge(w[1], "input")
    end
    for _, i in ipairs({ 1, 4, 6 }) do
      local b = at(o, 0, i)
      local e = belt_line(b, D.east, 2, "output")
      outs[#outs + 1] = swap_to_edge(e[1], "output")
      sinks[#sinks + 1] = sink(b, D.east, 2)
    end
    for k = 1, 3 do
      ins[k].connect_linked_belts(outs[k])
    end
    for _, edge in ipairs(ins) do
      local nb = edge.belt_neighbours
      assert(#nb.inputs == 1 and #nb.outputs == 0, "input edge at " .. serpent.line(edge.position)
        .. " has " .. #nb.inputs .. " inputs, " .. #nb.outputs .. " outputs")
    end
    for _, edge in ipairs(outs) do
      local nb = edge.belt_neighbours
      assert(#nb.inputs == 0 and #nb.outputs == 1, "output edge at " .. serpent.line(edge.position)
        .. " has " .. #nb.inputs .. " inputs, " .. #nb.outputs .. " outputs")
    end
    measure(sinks, 600, function(rates)
      report("(e) 1x8 row, 8 input edges and 3 output edges placed; outputs %.2f, %.2f, %.2f items/s",
        rates[1], rates[2], rates[3])
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

  -- The block-tile interface has allow_side_loading = false: an underground exit pointing
  -- into its side does not connect, so foreign items cannot enter through it.
  test("spike_block_tile_interface_refuses_side_loading", function()
    async(900)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local core = ce({ name = "mb-spike-lb", position = at(o, 0, 0), direction = D.east, type = "input" })
    belt_line(o, D.west, 2, "input")
    source(o, D.west, 2)
    ce({ name = UNDERGROUND, position = at(o, 0, -1), direction = D.south, type = "output" })
    ce({ name = UNDERGROUND, position = at(o, 0, -4), direction = D.south, type = "input" })
    belt_line(at(o, 0, -4), D.north, 1, "input")
    source(at(o, 0, -4), D.north, 1, "copper-plate")
    local e = belt_line(o, D.east, 2, "output")
    core.connect_linked_belts((swap_to_edge(e[1], "output")))
    local s = sink(o, D.east, 2)
    after_ticks(600, function()
      local nb = core.belt_neighbours
      local copper, iron = s.get_item_count("copper-plate"), s.get_item_count("iron-plate")
      report("(hybrid) side-fed block-tile interface: %d inputs; sink got %d iron, %d copper",
        #nb.inputs, iron, copper)
      assert(#nb.inputs == 1, "the side underground connected to the block-tile interface")
      assert(copper == 0 and iron > 0, "foreign items entered through the block-tile interface")
      done()
    end)
  end)

  -- A side-fed output tile: a foreign belt points into the side of an output edge whose
  -- network side carries nothing yet. With allow_side_loading = false (mb-spike-edge-out)
  -- nothing merges; with side loading allowed (mb-spike-edge used as an output) the foreign
  -- items flow into the balancer output.
  test("spike_output_edge_side_loading", function()
    async(900)
    local sinks = {}
    for k, name in ipairs({ "mb-spike-edge-out", "mb-spike-edge" }) do
      local o = origin()
      ce({ name = "mb-spike-block", position = at(o, 0, 0) })
      local e = belt_line(o, D.east, 2, "output")
      local out = swap_to_edge(e[1], "output", nil, name)
      local side = at(o, 1, 0)
      belt_line(side, D.north, 2, "input")
      source(side, D.north, 2, "copper-plate")
      sinks[k] = { sink(o, D.east, 2), out }
    end
    after_ticks(600, function()
      local r = {}
      for k, sk in ipairs(sinks) do
        r[k] = { sk[1].get_item_count("copper-plate"), #sk[2].belt_neighbours.inputs }
      end
      report("(e) side-fed output edge: no side loading -> %d foreign items, %d inputs; side loading -> %d foreign items, %d inputs",
        r[1][1], r[1][2], r[2][1], r[2][2])
      assert(r[1][1] == 0 and r[1][2] == 0, "foreign items merged into an output edge without side loading")
      assert(r[2][1] > 0, "side loading variant did not merge (comparison is meaningless)")
      done()
    end)
  end)

  -- A belt tile shared by two blocks: block A's output points into block B. One linked belt
  -- cannot be A's output edge and B's input edge, so the rule is an internal link: A's network
  -- output is linked straight to B's network input and the shared tile is left as it is.
  test("spike_shared_tile_internal_link", function()
    async(3000)
    local o = origin()
    local a, b = at(o, 0, 0), at(o, 2, 0)
    ce({ name = "mb-spike-block", position = a })
    ce({ name = "mb-spike-block", position = b })
    local shared = ce({ name = BELT, position = at(o, 1, 0), direction = D.east })
    shared.get_transport_line(LINES[1]).insert_at(0.25, { name = "copper-plate", count = 1 })
    local w = belt_line(a, D.west, 3, "input")
    source(a, D.west, 3)
    local e = belt_line(b, D.east, 3, "output")
    local ain = swap_to_edge(w[1], "input")
    local bout = swap_to_edge(e[1], "output")
    local a_head, a_tail = hidden_chain(at(o, 0, 10), 2) -- stands in for A's network
    local b_head, b_tail = hidden_chain(at(o, 0, 12), 2) -- stands in for B's network
    ain.connect_linked_belts(a_head)
    a_tail.connect_linked_belts(b_head) -- the internal link
    b_tail.connect_linked_belts(bout)
    local s = sink(b, D.east, 3)
    measure({ s }, 600, function(rates)
      local nb = shared.belt_neighbours
      report("(e) shared tile, internal link: %.2f items/s; shared tile has %d items, %d inputs, %d outputs",
        rates[1], items_on(shared), #nb.inputs, #nb.outputs)
      assert(rates[1] >= RATE * 0.99, "throughput " .. rates[1] .. " below a full belt")
      assert(items_on(shared) == 1 and #nb.inputs == 0 and #nb.outputs == 0, "the shared tile changed")
    end)
  end)

  -- Two belt tiles between two blocks: each tile is an ordinary edge (A's output edge feeds
  -- B's input edge directly).
  test("spike_two_tile_gap_edges_chain", function()
    async(3000)
    local o = origin()
    local a, b = at(o, 0, 0), at(o, 3, 0)
    ce({ name = "mb-spike-block", position = a })
    ce({ name = "mb-spike-block", position = b })
    ce({ name = BELT, position = at(o, 1, 0), direction = D.east })
    ce({ name = BELT, position = at(o, 2, 0), direction = D.east })
    local w = belt_line(a, D.west, 3, "input")
    source(a, D.west, 3)
    local e = belt_line(b, D.east, 3, "output")
    local ain = swap_to_edge(w[1], "input")
    local aout = swap_to_edge(at(o, 1, 0), "output")
    local bin = swap_to_edge(at(o, 2, 0), "input")
    local bout = swap_to_edge(e[1], "output")
    ain.connect_linked_belts(aout)
    bin.connect_linked_belts(bout)
    local s = sink(b, D.east, 3)
    measure({ s }, 600, function(rates)
      report("(e) two-tile gap, A output edge -> B input edge: %.2f items/s; A out has %d outputs",
        rates[1], #aout.belt_neighbours.outputs)
      assert(#aout.belt_neighbours.outputs == 1, "A's output edge does not feed B's input edge")
      assert(rates[1] >= RATE * 0.99, "throughput " .. rates[1] .. " below a full belt")
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
    local partner = ce({ name = "mb-spike-edge-out", position = at(o, 0, 5), direction = D.east, type = "output" })
    local edge, st = swap_to_edge(tiles[1], "input", partner)
    report("(e) swap of a full belt tile, partner with room: %d on the edge (line length %.3f), %d on the partner, %d forced",
      st.edge, edge.get_transport_line(LINES[1]).line_length, st.partner, st.forced)
    assert(items_on(edge) == st.edge and items_on(partner) == st.partner, "counts do not match")
    assert(st.edge + st.partner + st.forced == 8, "items unaccounted for")
  end)

  -- The normal product case: the network side is full (back-pressure) when a belt is
  -- attached. Swap a full tile with the partner and its line full, then open the line and
  -- check every item arrives exactly once.
  test("spike_edge_swap_partner_full_conserves_items", function()
    async(1500)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local tiles = belt_line(o, D.west, 1, "input")
    local belt = assert(surface.find_entity(BELT, tiles[1]), "belt missing")
    local on_tile = fill(belt)
    local p = at(o, 0, 5)
    local partner = ce({ name = "mb-spike-edge-out", position = p, direction = D.east, type = "output" })
    local downstream = {}
    for i = 1, 3 do
      downstream[i] = ce({ name = BELT, position = at(p, i, 0), direction = D.east })
    end
    local prefill = fill(partner)
    for _, d in ipairs(downstream) do prefill = prefill + fill(d) end
    local edge, st = swap_to_edge(tiles[1], "input", partner)
    local total = items_on(edge) + items_on(partner)
    for _, d in ipairs(downstream) do total = total + items_on(d) end
    report("(e) swap with a full partner: tile %d (edge %d, partner %d, forced %d), network side %d, total now %d of %d",
      on_tile, st.edge, st.partner, st.forced, prefill, total, on_tile + prefill)
    assert(total == on_tile + prefill, "items lost or duplicated by the swap")
    ce({ name = "mb-spike-io-loader", position = at(p, 4, 0), direction = D.east, type = "input" })
    local chest = ce({ name = "steel-chest", position = at(p, 5, 0) })
    after_ticks(900, function()
      local left = items_on(edge) + items_on(partner)
      for _, d in ipairs(downstream) do left = left + items_on(d) end
      report("(e) after draining: chest %d, left on belts %d (expected %d, 0)", chest.get_item_count(), left, total)
      assert(chest.get_item_count() == total and left == 0, "items lost or duplicated while draining")
      done()
    end)
  end)

  -- A backed-up, still-fed line (finite source of 400 plates) is swapped while the source
  -- keeps pushing; everything must arrive exactly once.
  test("spike_edge_swap_in_backed_up_line_conserves_items", function()
    async(2400)
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local w = belt_line(o, D.west, 3, "input")
    local src = ce({ name = "steel-chest", position = step(o, D.west, 5) })
    src.insert({ name = "iron-plate", count = 400 })
    ce({ name = "mb-spike-io-loader", position = step(o, D.west, 4), direction = D.east, type = "output" })
    local p = at(o, 0, 5)
    local partner = ce({ name = "mb-spike-edge-out", position = p, direction = D.east, type = "output" })
    ce({ name = BELT, position = at(p, 1, 0), direction = D.east })
    ce({ name = "mb-spike-io-loader", position = at(p, 2, 0), direction = D.east, type = "input" })
    local chest = ce({ name = "steel-chest", position = at(p, 3, 0) })
    after_ticks(120, function()
      local belt = assert(surface.find_entity(BELT, w[1]), "belt missing")
      local before = items_on(belt)
      local _, st = swap_to_edge(w[1], "input", partner)
      report("(e) swap in a backed-up line: source chest %d left, tile had %d (edge %d, partner %d, forced %d)",
        src.get_item_count(), before, st.edge, st.partner, st.forced)
      after_ticks(1500, function()
        report("(e) backed-up line after draining: chest %d of 400, source %d", chest.get_item_count(), src.get_item_count())
        assert(src.get_item_count() == 0, "source not drained")
        assert(chest.get_item_count() == 400, "items lost or duplicated: " .. chest.get_item_count() .. " of 400")
        done()
      end)
    end)
  end)

  -- Belt stacks (Space Age stacks up to 4 per belt slot): the swap keeps stack sizes.
  test("spike_edge_swap_keeps_belt_stacks", function()
    local o = origin()
    local tiles = belt_line(o, D.west, 1, "input")
    local belt = assert(surface.find_entity(BELT, tiles[1]), "belt missing")
    local line = belt.get_transport_line(LINES[1])
    local inserted = line.insert_at(0.25, { name = "iron-plate", count = 4 }, 4)
    local before = {}
    for _, it in ipairs(line.get_detailed_contents()) do before[#before + 1] = it.stack.count end
    local partner = ce({ name = "mb-spike-edge-out", position = at(o, 0, 5), direction = D.east, type = "output" })
    local edge = swap_to_edge(tiles[1], "input", partner)
    local after = {}
    for _, it in ipairs(edge.get_transport_line(LINES[1]).get_detailed_contents()) do after[#after + 1] = it.stack.count end
    report("(e) belt stack: insert of 4 as one stack %s; stacks before %s, after %s",
      tostring(inserted), serpent.line(before), serpent.line(after))
    assert(serpent.line(before) == serpent.line(after), "stack sizes changed")
  end)

  test("spike_edge_mines_to_belt_item", function()
    local o = origin()
    local tiles = belt_line(o, D.west, 1, "input")
    local belt = assert(surface.find_entity(BELT, tiles[1]), "belt missing")
    belt.get_transport_line(LINES[1]).insert_at(0.25, { name = "copper-plate", count = 1 })
    local edge = swap_to_edge(tiles[1], "input")
    local inv = game.create_inventory(8)
    local mined = edge.mine({ inventory = inv })
    local got = inv.get_contents()
    inv.destroy()
    report("(e) mining an edge: %s, inventory %s", tostring(mined), serpent.line(got))
    local belts, copper = 0, 0
    for _, c in pairs(got) do
      if c.name == BELT then belts = belts + c.count end
      if c.name == "copper-plate" then copper = copper + c.count end
    end
    assert(mined and belts == 1 and copper == 1, "mining did not give back the belt and its item")
  end)

  -- What a blueprint of an edge records, and whether a script can rewrite it to the belt.
  test("spike_edge_blueprint_records", function()
    local o = origin()
    ce({ name = "mb-spike-block", position = at(o, 0, 0) })
    local w = belt_line(o, D.west, 2, "input")
    swap_to_edge(w[1], "input")
    local inv = game.create_inventory(1)
    inv.insert({ name = "blueprint" })
    local bp = inv[1]
    bp.create_blueprint({ surface = surface, force = "player", area = { at(o, -3, -1), at(o, 1, 1) } })
    local names = {}
    local entities = bp.get_blueprint_entities() or {}
    for _, be in ipairs(entities) do names[#names + 1] = be.name end
    table.sort(names)
    for _, be in ipairs(entities) do
      if be.name == "mb-spike-edge" then
        be.name = BELT
        be.type = nil
      end
    end
    bp.set_blueprint_entities(entities)
    local rewritten = {}
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do rewritten[#rewritten + 1] = be.name end
    table.sort(rewritten)
    inv.destroy()
    report("(e) blueprint of an edge records %s; rewritten by script: %s",
      serpent.line(names), serpent.line(rewritten))
    local has_edge = false
    for _, n in ipairs(names) do if n == "mb-spike-edge" then has_edge = true end end
    assert(has_edge, "the blueprint did not record the edge")
    for _, n in ipairs(rewritten) do assert(n ~= "mb-spike-edge", "rewrite left the edge in the blueprint") end
  end)

  -- Drag-building / fast-replacing a belt over an edge. The vanilla linked belt is in the
  -- "linked-belts" fast-replace group; mb-spike-edge-frg is in "transport-belt".
  test("spike_edge_fast_replace", function()
    local o = origin()
    local r = {}
    for k, name in ipairs({ "mb-spike-edge", "mb-spike-edge-frg" }) do
      local p = at(o, 0, k * 3)
      local edge = ce({ name = name, position = p, direction = D.east, type = "input" })
      local can = surface.can_fast_replace({ name = BELT, position = p, direction = D.east, force = "player" })
      local placed = surface.create_entity({
        name = BELT, position = p, direction = D.east, force = "player", fast_replace = true, spill = false,
      })
      r[k] = { can = can, result = placed and placed.name or "refused", edge_valid = edge.valid }
    end
    report("(e) fast-replace a belt over an edge: linked-belts group -> can %s, %s; transport-belt group -> can %s, %s (edge valid %s)",
      tostring(r[1].can), r[1].result, tostring(r[2].can), r[2].result, tostring(r[2].edge_valid))
    assert(r[1].result == "refused", "a belt replaced an edge in the linked-belts group")
  end)
end)
