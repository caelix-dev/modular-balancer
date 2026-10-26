-- Ports of a balancer (scripts/io.lua through scripts/balancer.lua): edge prototypes, swapping a
-- belt tile and back with its items, the block-tile interface, refusals and Ruling 6. Entities
-- are built with raise_built, as a player would. Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")
local belt_io = require("scripts.io")

local D = defines.direction

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

local function rec_of(block)
  local id = groups.of(block.unit_number)
  return assert(balancer.get(id), "no balancer for group " .. tostring(id))
end

local function reasons(rec)
  local set = {}
  for _, r in ipairs(rec.refused) do
    set[r.reason] = true
  end
  return set
end

describe("io", function()
  after_each(function()
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- One input and one output edge per transport belt, at the belt's speed, mining to its item.
  test("edges_per_belt_prototype", function()
    local n = 0
    for name, belt in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
      for _, role in ipairs({ "in", "out" }) do
        local e = prototypes.entity["mb-edge-" .. role .. "-" .. name]
        assert(e and e.type == "linked-belt", "no " .. role .. " edge for " .. name)
        assert(e.belt_speed == belt.belt_speed, name .. " " .. role .. " edge speed " .. e.belt_speed)
        local want, got = belt.mineable_properties.products, e.mineable_properties.products
        assert(serpent.line(want) == serpent.line(got), name .. " " .. role .. " edge mines to " .. serpent.line(got))
        n = n + 1
      end
    end
    assert(n >= 6, "only " .. n .. " edges")
  end)

  -- Plan 3 Task 2 (spec Update 2026-10-25, edge look): an edge looks and behaves like its belt.
  -- Every edge has the belt's fast-replace group, and is hidden (in no planner list, never an
  -- upgrade source) with no next upgrade. A swapped edge carries
  -- one drawing of the belt's straight animation for its direction (the half tile a linked belt
  -- leaves blank), which goes with the edge.
  test("edges_look_like_belts", function()
    for name, belt in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
      for _, role in ipairs({ "in", "out" }) do
        local e = prototypes.entity["mb-edge-" .. role .. "-" .. name]
        assert(e and e.type == "linked-belt", "no " .. role .. " edge for " .. name)
        assert(e.fast_replaceable_group == belt.fast_replaceable_group, name .. " " .. role .. " edge replace group " .. tostring(e.fast_replaceable_group))
        assert(e.hidden and e.hidden_in_factoriopedia and not e.next_upgrade, name .. " " .. role .. " edge is listed or upgradable")
      end
      for _, dir in ipairs({ "north", "east", "south", "west" }) do
        assert(helpers.is_valid_animation_path("mb-edge-belt-" .. name .. "-" .. dir), "no " .. dir .. " animation for " .. name)
      end
    end
    local o = area(8, 8)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.north, 2, { stock = 0 })
    H.sink(o, 4, 4, D.west, 2)
    balancer.flush()
    -- the mod's drawings on entity `e`
    ---@param e LuaEntity
    ---@return LuaRenderObject[]
    local function drawings(e)
      local list = {}
      for _, obj in ipairs(rendering.get_all_objects(script.mod_name)) do
        local t = obj.target
        if t and t.entity == e then
          list[#list + 1] = obj
        end
      end
      return list
    end
    local ein, eout = H.at(o, 4, 3, "linked-belt"), H.at(o, 3, 4, "linked-belt")
    assert(ein and eout, "edges not swapped")
    local li, lout = drawings(ein), drawings(eout)
    assert(#li == 1 and #lout == 1, "drawings per edge: " .. #li .. ", " .. #lout)
    local di, dout = li[1], lout[1]
    assert(di.animation == "mb-edge-belt-" .. H.BELT .. "-south", "input edge drawing: " .. di.animation)
    assert(dout.animation == "mb-edge-belt-" .. H.BELT .. "-west", "output edge drawing: " .. dout.animation)
    assert(di.render_layer == "floor", "drawn on layer " .. tostring(di.render_layer))
    -- a configuration change draws what is missing (an old save), once
    di.destroy()
    assert(belt_io.dress_all() == 1, "dress_all did not draw exactly the missing edge")
    li = drawings(ein)
    assert(#li == 1 and #drawings(eout) == 1, "drawings after dress_all: " .. #li .. ", " .. #drawings(eout))
    di = li[1]
    b.destroy({ raise_destroy = true })
    balancer.flush()
    assert(not di.valid and not dout.valid, "the drawings outlived their edges")
  end)

  -- Review minor 4: edges built by the game are dressed too. A clone of an edge (on_entity_cloned,
  -- loose until a flush) carries exactly one drawing, which goes when the flush swaps it back.
  -- An alternate belt (turbo, Space Age only) uses the "-odd" animation on tiles with x + y odd.
  test("loose_edges_dressed", function()
    local o = area(12, 9)
    local s = game.surfaces.nauvis
    H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 2, { stock = 0 })
    H.sink(o, 4, 4, D.east, 2)
    balancer.flush()
    ---@param e LuaEntity
    ---@return LuaRenderObject[]
    local function drawings(e)
      local list = {}
      for _, obj in ipairs(rendering.get_all_objects(script.mod_name)) do
        local t = obj.target
        if t and t.entity == e then
          list[#list + 1] = obj
        end
      end
      return list
    end
    local base = #rendering.get_all_objects(script.mod_name)
    local edge = H.at(o, 3, 4, "linked-belt")
    assert(edge, "no edge")
    local clone = edge.clone({ position = { o.x + 1, o.y + 1 }, create_build_effect_smoke = false })
    assert(clone, "not cloned")
    assert(#drawings(clone) == 1, "drawings on the clone: " .. #drawings(clone))
    balancer.flush()
    assert(not clone.valid and #rendering.get_all_objects(script.mod_name) == base, "the clone or its drawing was left behind")
    local name = "mb-edge-belt-turbo-transport-belt-east"
    if helpers.is_valid_animation_path(name .. "-odd") then
      for dx = 1, 2 do
        local e = H.put(o, dx, 7, "mb-edge-in-turbo-transport-belt", D.east, { type = "input" })
        local x, y = math.floor(e.position.x), math.floor(e.position.y)
        local want = (x + y) % 2 == 1 and name .. "-odd" or name
        local d = drawings(e)
        assert(#d == 1 and d[1].animation == want, "turbo edge at " .. x .. "," .. y .. ": " .. tostring(d[1] and d[1].animation))
      end
      balancer.flush()
    end
  end)

  -- A full belt tile swapped for an edge and back keeps every item: the input and output tiles
  -- become edges when the block becomes a balancer, and plain belts again (with their items)
  -- when the block is removed. The network's items are spilled at the block, so nothing is lost.
  test("removing_block_restores_belts_with_items", function()
    async(700)
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 300 })
    local out = H.sink(o, 4, 4, D.east, 3)
    out.loader.destroy() -- the output backs up, so the tiles next to the block are full
    balancer.flush()
    local ein, eout = H.at(o, 3, 4, "linked-belt"), H.at(o, 5, 4, "linked-belt")
    assert(ein and ein.name == "mb-edge-in-" .. H.BELT, "input tile not swapped")
    assert(eout and eout.name == "mb-edge-out-" .. H.BELT, "output tile not swapped")
    after_ticks(600, function()
      local before = H.count_box(box, "iron-plate")
      assert(before == 300, "before the removal: " .. before .. " of 300")
      b.destroy({ raise_destroy = true })
      balancer.flush()
      local west, east = H.at(o, 3, 4, "transport-belt"), H.at(o, 5, 4, "transport-belt")
      assert(west and west.name == H.BELT and east and east.name == H.BELT, "edges not swapped back")
      assert(H.at(o, 3, 4, "linked-belt") == nil and H.at(o, 5, 4, "linked-belt") == nil, "edges left behind")
      assert(west.direction == D.east and east.direction == D.east, "directions changed")
      local after = H.count_box(box, "iron-plate")
      H.report("removing_block_restores_belts: %d before, %d after (west tile %d, east tile %d)", before, after,
        H.items_on(west), H.items_on(east))
      assert(after == 300, "after the removal: " .. after .. " of 300")
      done()
    end)
  end)

  -- Ruling 6: a belt built on a block tile is undone and its item handed back (spilled here,
  -- with no player or robot).
  test("belt_on_block_is_returned", function()
    local o = area(6, 6)
    H.block(o, 3, 3, H.TIER)
    local s = game.surfaces.nauvis
    local belt = s.create_entity({ name = H.BELT, position = { o.x + 3, o.y + 3 }, direction = D.east, force = "player", raise_built = true })
    assert(belt == nil or not belt.valid, "the belt on the block was kept")
    assert(H.at(o, 3, 3, "transport-belt") == nil, "a belt is still on the block tile")
    local items = s.find_entities_filtered({ area = { { o.x, o.y }, { o.x + 6, o.y + 6 } }, type = "item-entity" })
    local n = 0
    for _, it in ipairs(items) do
      if it.stack.name == H.BELT then
        n = n + it.stack.count
      end
    end
    assert(n == 1, n .. " belt items on the ground, expected 1")
  end)

  -- A straight output tile with side inputs would merge foreign items into the output: refused.
  test("side_loaded_output_refused", function()
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    H.put(o, 5, 4, H.BELT, D.east)
    H.put(o, 5, 3, H.BELT, D.south)
    H.put(o, 5, 5, H.BELT, D.north)
    local tile = H.at(o, 5, 4, "transport-belt")
    assert(tile and tile.belt_shape == "straight", "test setup: the tile is curved")
    balancer.flush()
    local rec = rec_of(b)
    assert(reasons(rec)["side-loaded"], "not refused: " .. serpent.line(rec.refused))
    assert(rec.m == 0 and not rec.placed, "a network was built")
    assert(H.at(o, 5, 4, "transport-belt"), "the side-loaded tile was swapped")
  end)

  -- An underground exit pointing into a block cannot be swapped: the block tile holds the
  -- interface, a linked belt facing it, and the input works. A second one is refused (sides are
  -- taken north, east, south, west, so the west one here).
  test("underground_neighbour_uses_block_tile", function()
    async(1500)
    local o = area(12, 12)
    local b = H.block(o, 5, 5, H.TIER)
    local ug = "express-underground-belt"
    H.put(o, 5, 2, ug, D.south, { type = "input" })
    H.put(o, 5, 4, ug, D.south, { type = "output" })
    H.put(o, 5, 1, "mb-test-loader-" .. H.TIER, D.south, { type = "output" })
    H.put(o, 5, 0, "mb-test-chest").insert({ name = "iron-plate", count = 500 })
    local out = H.sink(o, 5, 5, D.east, 3)
    -- a second underground exit, from the west
    H.put(o, 2, 5, ug, D.east, { type = "input" })
    H.put(o, 4, 5, ug, D.east, { type = "output" })
    balancer.flush()
    local rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    local port = assert(rec.inputs[1], "no input")
    assert(port.kind == "tile", "input is a " .. port.kind .. ", expected the block-tile interface")
    local lb = port.visible
    assert(lb and lb.name == "mb-hidden-linked-belt-" .. H.TIER and lb.linked_belt_type == "input" and lb.direction == D.south,
      "block-tile interface wrong: " .. serpent.line(lb and { lb.name, lb.linked_belt_type, lb.direction }))
    assert(reasons(rec)["two-unswappable"], "second underground not refused: " .. serpent.line(rec.refused))
    after_ticks(1200, function()
      assert(out.chest.get_item_count() > 100, "only " .. out.chest.get_item_count() .. " plates through the interface")
      done()
    end)
  end)

  -- Ruling 6 the other way round: a block built on an edge tile is refused like a block on a
  -- plain belt, and the edge keeps working.
  test("block_on_edge_tile_refused", function()
    local o, box = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local edge = H.at(o, 5, 4, "linked-belt")
    assert(edge and edge.name == "mb-edge-out-" .. H.BELT, "no output edge")
    local s = game.surfaces.nauvis
    local nb = s.create_entity({ name = "mb-balancer-" .. H.TIER, position = { o.x + 5, o.y + 4 }, force = "player", raise_built = true })
    assert(nb == nil or not nb.valid, "the block on the edge was kept")
    balancer.flush()
    assert(edge.valid, "the edge was removed")
    local rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    local n = 0
    for _, it in ipairs(s.find_entities_filtered({ area = box, type = "item-entity" })) do
      if it.stack.name == "mb-balancer-" .. H.TIER then
        n = n + it.stack.count
      end
    end
    assert(n == 1, n .. " block items on the ground, expected 1")
  end)

  -- Ruling 6 with a robot: a construction robot builds a belt ghost on a block tile; the belt is
  -- undone and handed to the robot (nothing on the ground), and the item comes back to storage.
  test("belt_on_block_returned_to_robot", function()
    async(3700)
    local o, box = area(12, 12)
    H.block(o, 3, 3, H.TIER)
    local s = game.surfaces.nauvis
    local port = H.ce(s, { name = "mb-test-roboport", position = { o.x + 8, o.y + 8 } })
    port.get_inventory(defines.inventory.roboport_robot).insert({ name = "construction-robot", count = 2 })
    local chest = H.ce(s, { name = "storage-chest", position = { o.x + 10, o.y + 3 } })
    chest.insert({ name = H.BELT, count = 1 })
    H.ce(s, { name = "entity-ghost", inner_name = H.BELT, position = { o.x + 3, o.y + 3 }, direction = D.east })
    ---@return number
    local function belts_held()
      local n = 0.0 + chest.get_item_count(H.BELT)
      for _, r in ipairs(s.find_entities_filtered({ area = box, type = "construction-robot" })) do
        local cargo = r.get_inventory(defines.inventory.robot_cargo)
        n = n + (cargo and cargo.get_item_count(H.BELT) or 0)
      end
      return n
    end
    ---@return number
    local function ground()
      local n = 0.0
      for _, it in ipairs(s.find_entities_filtered({ area = box, type = "item-entity" })) do
        n = n + it.stack.count
      end
      return n
    end
    local function wait(k, phase)
      after_ticks(30, function()
        if phase == "build" then
          if s.find_entities_filtered({ area = box, type = "entity-ghost" })[1] then
            assert(k > 0, "no robot built the ghost in 1 800 ticks")
            return wait(k - 1, "build")
          end
          assert(H.at(o, 3, 3, "transport-belt") == nil, "the robot-built belt stayed on the block")
          assert(ground() == 0, "the belt was spilled instead of handed to the robot")
          assert(belts_held() == 1, belts_held() .. " belts held by the chest and robots, expected 1")
          return wait(60, "home")
        end
        if chest.get_item_count(H.BELT) == 1 then
          done()
        else
          assert(k > 0, "the belt never came back to the storage chest")
          assert(belts_held() == 1, "belt lost on the way back")
          wait(k - 1, "home")
        end
      end)
    end
    wait(60, "build")
  end)

  -- Ruling 7: a wired belt next to a block is not swapped; the block-tile interface serves it, the
  -- belt keeps its wire, and items flow. A second wired belt on the same block is refused (sides
  -- are taken north, east, south, west: the north input first, the south output second).
  test("wired_belt_uses_block_tile_or_is_refused", function()
    async(700)
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.north, 3)
    local out = H.sink(o, 4, 4, D.east, 3)
    local south = H.sink(o, 4, 4, D.south, 3)
    local comb = H.put(o, 2, 4, "constant-combinator", D.north)
    local red = defines.wire_connector_id.circuit_red
    local cin = comb.get_wire_connector(red, true)
    local last_in = assert(H.at(o, 4, 3, "transport-belt"), "no input belt") --[[@as LuaEntity]]
    local last_south = south.belts[1] --[[@as LuaEntity]]
    local function wire(e)
      return e.get_wire_connector(red, true) --[[@as LuaWireConnector]]
    end
    assert(wire(last_in).connect_to(cin), "could not wire the input belt")
    assert(wire(last_south).connect_to(cin), "could not wire the south belt")
    balancer.flush()
    local rec = rec_of(b)
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
    local first = assert(rec.inputs[1], "no input")
    assert(first.kind == "tile", "the wired input is a " .. first.kind .. ", expected the block-tile interface")
    assert(reasons(rec)["wired-belt"], "the second wired belt was not refused: " .. serpent.line(rec.refused))
    assert(last_in.valid and wire(last_in).connection_count == 1, "the input belt lost its wire")
    assert(last_south.valid and last_south.type == "transport-belt" and wire(last_south).connection_count == 1,
      "the south belt was swapped or lost its wire")
    after_ticks(600, function()
      assert(out.chest.get_item_count() > 100, "only " .. out.chest.get_item_count() .. " plates through the interface")
      done()
    end)
  end)

  -- F3 re-check when a tile is swapped back (I3): block Y's inserter port faces north, where block
  -- X's output edge passes (an edge takes no side loading, so that side is free). X is removed,
  -- the edge becomes a plain belt again, and on the next tick Y's port turns away from it. Y is
  -- diagonal to X, so only the swap re-check reaches it.
  test("port_moves_when_neighbour_edge_unswapped", function()
    async(30)
    local o = area(12, 12)
    local x = H.block(o, 3, 2, H.TIER)
    local y = H.block(o, 4, 3, H.TIER)
    H.feed(o, 3, 2, D.west, 3)
    H.sink(o, 3, 2, D.east, 3)
    H.feed(o, 4, 3, D.west, 3)
    H.put(o, 4, 4, "mb-test-inserter", D.north)
    H.put(o, 4, 5, "mb-test-chest")
    balancer.flush()
    local port = assert(rec_of(y).outputs[1], "Y has no output")
    local pv = assert(port.kind == "inserter" and port.visible, "Y has no inserter port") --[[@as LuaEntity]]
    assert(pv.direction == D.north, "test setup: Y's port does not face the edge (" .. pv.direction .. ")")
    x.destroy({ raise_destroy = true })
    balancer.flush()
    local t = H.at(o, 4, 2, "transport-belt")
    assert(t and t.name == H.BELT, "X's edge was not swapped back")
    after_ticks(3, function()
      local out = assert(rec_of(y).outputs[1], "Y lost its output")
      local p = out.visible
      assert(p and p.valid, "Y lost its port")
      assert(#p.belt_neighbours.outputs == 0, "Y's port still feeds a belt")
      assert(p.direction ~= D.north, "Y's port still faces the plain belt")
      assert(next(storage.balancer.dirty) == nil, "groups still dirty: the re-check does not settle")
      done()
    end)
  end)

  -- Inserters both taking from and putting into one block: refused, no inserter port.
  test("inserter_both_refused", function()
    local o = area(10, 10)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3)
    H.sink(o, 4, 4, D.east, 3)
    H.put(o, 4, 3, "mb-test-inserter", D.south) -- picks from the block
    H.put(o, 4, 2, "mb-test-chest")
    H.put(o, 4, 5, "mb-test-inserter", D.south) -- picks from the south chest, drops on the block
    H.put(o, 4, 6, "mb-test-chest")
    balancer.flush()
    local rec = rec_of(b)
    assert(reasons(rec)["inserter-both"], "not refused: " .. serpent.line(rec.refused))
    assert(rec.n == 1 and rec.m == 1, "network " .. rec.n .. ":" .. rec.m .. ", expected 1:1")
  end)
end)
