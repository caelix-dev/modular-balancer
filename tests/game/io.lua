-- Ports of a balancer (scripts/io.lua through scripts/balancer.lua): edge prototypes, swapping a
-- belt tile and back with its items, the block-tile interface, refusals and Ruling 6. Entities
-- are built with raise_built, as a player would. Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")

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
