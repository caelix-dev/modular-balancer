-- Lifecycle of a balancer (scripts/lifecycle.lua, scripts/events.lua, scripts/balancer.lua):
-- blueprints, copy-paste, ghosts, undo and redo, the upgrade planner, mining edges, rotating and
-- flipping neighbours, a removed tier and a lost hidden surface. Entities are built with
-- raise_built, as a player would.
--
-- fdev test is headless and has no player, so the player-only events are driven the way the game
-- would drive them:
--   on_player_setup_blueprint   LuaItemCommon::create_blueprint, then the mod's handler called
--                               with the event fields it reads (stack)
--   undo / redo                 the game rebuilds a ghost (create_entity entity-ghost with
--                               raise_built) or marks for deconstruction; on_undo_applied is
--                               called with the UndoRedoAction tables it would carry
--   rotate / flip               LuaEntity::rotate / ::flip (they raise nothing without a player),
--                               then the mod's handler with the event fields
--   upgrade planner             LuaEntity::order_upgrade (raises on_marked_for_upgrade) and
--                               LuaEntity::apply_upgrade (raises script_raised_destroy / _built),
--                               as a robot would complete it
-- Construction robots are real (a roboport, robots and a storage chest).
-- Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")
local events = require("scripts.events")
local lifecycle = require("scripts.lifecycle")
local builder = require("scripts.builder")

local D = defines.direction
local WARMUP, WINDOW = 3000, 3600
local RATE = H.RATE
local ITEM = "iron-plate"

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

local function rec_of(block)
  local id = groups.of(block.unit_number)
  return assert(balancer.get(id), "no balancer for group " .. tostring(id)), id
end

-- Asserts |v - want| <= 1 % of want.
local function near(v, want, what)
  assert(math.abs(v - want) <= want * 0.01, string.format("%s: %.3f, expected %.3f within 1 %%", what, v, want))
end

local function nm(rec)
  return rec.n .. ":" .. rec.m
end

-- Every entity in `box` whose name starts with mb-edge- or mb-hidden- (the mod's own entities on
-- the player's side).
local function ours_in(box)
  local list = {}
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "linked-belt" })) do
    if e.name:sub(1, 8) == "mb-edge-" or e.name:sub(1, 10) == "mb-hidden-" then
      list[#list + 1] = e
    end
  end
  return list
end

-- A blueprint in a script inventory of the entities in `bbox`. Returns the stack and the
-- inventory (destroy it when done).
local function blueprint_of(bbox)
  local inv = game.create_inventory(1)
  inv.insert({ name = "blueprint" })
  local bp = inv[1]
  bp.create_blueprint({ surface = game.surfaces.nauvis, force = "player", area = bbox })
  return bp, inv
end

-- Revives every ghost in `box` with raise_revive (as robots or the player would build them).
-- Returns the number revived.
---@return integer
local function revive_all(box)
  local n = 0
  for _, g in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "entity-ghost" })) do
    if g.valid then
      local _, e = g.revive({ raise_revive = true })
      if e then
        n = n + 1
      end
    end
  end
  return n
end

-- Pastes `bp` at `position` (ghosts, raise_built so the build events see them as a player paste
-- would) and revives every ghost in `box`. Returns the number of ghosts revived.
---@return integer
local function paste(bp, position, box)
  bp.build_blueprint({ surface = game.surfaces.nauvis, force = "player", position = position, build_mode = defines.build_mode.forced, raise_built = true })
  return revive_all(box)
end

-- The blocks in `box`, sorted by row then column.
---@return LuaEntity[]
local function blocks_in(box)
  ---@type LuaEntity[]
  local list = {}
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "simple-entity-with-owner" })) do
    if groups.tier_of(e.name) then
      list[#list + 1] = e
    end
  end
  table.sort(list, function(a, b)
    if a.position.y ~= b.position.y then
      return a.position.y < b.position.y
    end
    return a.position.x < b.position.x
  end)
  return list
end

-- Loaders and chests are not minable in the harness, so blueprints leave them out: after a
-- paste, `source` builds a loader facing `dir` at tile (o.x + dx, o.y + dy) with a full chest
-- behind it, and `drain` a sink loader with a chest after it. Both return the chest.
local function source(o, dx, dy, dir, stock)
  local v = H.VEC[dir]
  H.put(o, dx, dy, "mb-test-loader-" .. H.TIER, dir, { type = "output" })
  local chest = H.put(o, dx - v[1], dy - v[2], "mb-test-chest")
  chest.insert({ name = ITEM, count = stock or H.SOURCE_STOCK })
  return chest
end
local function drain(o, dx, dy, dir)
  local v = H.VEC[dir]
  H.put(o, dx, dy, "mb-test-loader-" .. H.TIER, dir, { type = "input" })
  return H.put(o, dx + v[1], dy + v[2], "mb-test-chest")
end

-- The area origin that puts `block` where tile (dx, dy) of an area would be.
local function origin_of(block, dx, dy)
  return { x = block.position.x - dx, y = block.position.y - dy }
end

-- A roboport with construction robots and a storage chest (empty) at (o.x + dx, o.y + dy).
local function robots(o, dx, dy)
  local s = game.surfaces.nauvis
  local port = H.ce(s, { name = "mb-test-roboport", position = { o.x + dx, o.y + dy } })
  port.get_inventory(defines.inventory.roboport_robot).insert({ name = "construction-robot", count = 10 })
  local chest = H.ce(s, { name = "storage-chest", position = { o.x + dx + 4, o.y + dy } })
  return port, chest
end

-- Calls `check()` every 30 ticks until it returns true, at most `tries` times, then `k()`.
-- `check` may return false and a description of the state, shown on a timeout.
local function wait_for(what, tries, check, k)
  after_ticks(30, function()
    local ok, state = check()
    if ok then
      k()
    else
      assert(tries > 0, what .. ": timed out" .. (state and (" (" .. state .. ")") or ""))
      wait_for(what, tries - 1, check, k)
    end
  end)
end

-- Blocks an output (H.sink result): its loader is removed, so the belts and the network back up.
-- release(out) puts the loader back.
local function block(out)
  local l = out.loader
  out.saved = { position = l.position, direction = l.direction }
  l.destroy()
end
local function release(out)
  out.loader = H.ce(game.surfaces.nauvis, {
    name = "mb-test-loader-" .. H.TIER, position = out.saved.position, direction = out.saved.direction, type = "input",
  })
end

-- Items in the sink chests `outs` (H.sink results).
---@return number
local function delivered(outs)
  local n = 0
  for _, r in ipairs(outs) do
    n = n + r.chest.get_item_count()
  end
  return n
end

-- Items lying on tile (x, y) of nauvis.
---@return number
local function ground_on(x, y)
  local n = 0
  for _, it in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = { { x - 0.5, y - 0.5 }, { x + 0.5, y + 0.5 } }, type = "item-entity" })) do
    n = n + it.stack.count
  end
  return n
end

local default_take = builder.take

describe("lifecycle", function()
  after_each(function()
    builder.max_take_slots = 65535
    builder.max_buffer_slots = 65535
    builder.take = default_take
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- Final review I1: builder.take never sizes an inventory by item count. With its cap lowered to
  -- one slot, a backed-up balancer holding iron and copper plates, destroyed with nobody mining
  -- it, is taken into several inventories; every item is spilled (off the block's tile).
  test("take_uses_bounded_inventories", function()
    async(900)
    local o, box = area(10, 9)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 300 })
    H.feed(o, 4, 4, D.north, 3, { stock = 300, item = "copper-plate" })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(600, function()
      local iron, copper = H.count_box(box, "iron-plate"), H.count_box(box, "copper-plate")
      assert(iron == 300 and copper == 300, "before: " .. iron .. " / " .. copper)
      local id = groups.of(b.unit_number)
      local items = {}
      for _, it in ipairs(builder.contents(rec_of(b).placed)) do
        items[it.name] = it.count
      end
      assert((items["iron-plate"] or 0) > 0 and (items["copper-plate"] or 0) > 0, "test setup: network holds " .. serpent.line(items))
      builder.max_take_slots = 1
      local invs = 0
      builder.take = function(p)
        local list, n = default_take(p)
        invs = invs + #list
        for _, inv in ipairs(list) do
          if #inv > 1 then
            error("an inventory of " .. #inv .. " slots with the cap at 1")
          end
        end
        return list, n
      end
      local pos = b.position
      b.destroy({ raise_destroy = true })
      balancer.flush()
      assert(invs >= 2, "take used " .. invs .. " inventories, expected at least 2")
      assert(ground_on(pos.x, pos.y) == 0, "items spilled on the block's tile")
      iron, copper = H.count_box(box, "iron-plate"), H.count_box(box, "copper-plate")
      assert(iron == 300 and copper == 300, "after: " .. iron .. " / " .. copper)
      done()
    end)
  end)

  -- Final review I1, carry: a shrink whose leftover plates are hundreds of single belt items but
  -- a couple of stacks once merged rebuilds with the buffer capped at 3 slots (it used to be
  -- refused as too many items, counting the unmerged stacks).
  test("carry_merges_into_a_capped_buffer", function()
    async(900)
    local o, box = area(10, 9)
    local stock = 600
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out1 = H.sink(o, 4, 4, D.east, 3)
    local out2 = H.sink(o, 4, 4, D.south, 3)
    block(out1)
    block(out2)
    balancer.flush()
    after_ticks(600, function()
      local rec, id = rec_of(b)
      assert(nm(rec) == "1:2", "network " .. nm(rec))
      local before = H.network_of(id)
      assert(before > 3, "test setup: only " .. before .. " in the network")
      builder.max_buffer_slots = 3
      -- the south output goes: 1:2 -> 1:1, the network shrinks
      -- its last tile is an edge now; mined with its items into a chest of the box
      local edge = assert(H.at(o, 4, 5, "linked-belt"), "no south edge")
      local keep = H.ce(game.surfaces.nauvis, { name = "mb-test-chest", position = { o.x + 8, o.y + 8 } })
      assert(edge.mine({ inventory = keep.get_inventory(defines.inventory.chest), raise_destroyed = true }), "edge not mined")
      balancer.flush()
      local rec2 = rec_of(b)
      assert(nm(rec2) == "1:1", "the shrink was refused: " .. nm(rec2) .. " " .. serpent.line(rec2.refused))
      -- more single belt items went to the buffer than it has slots: the old pre-check refused this
      local buffered = rec2.placed.buffer.get_item_count()
      if buffered <= 3 then
        error("test setup: only " .. buffered .. " items went to the buffer")
      end
      assert(H.count_box(box, ITEM) == stock, "after the shrink: " .. H.count_box(box, ITEM) .. " of " .. stock)
      done()
    end)
  end)

  -- Final review Minor 1: a belt of another force pointing into a block is never swapped or
  -- linked; it is refused ("other-force").
  test("belt_of_another_force_ignored", function()
    local o = area(10, 9)
    local other = game.forces["mb-test-other"] or game.create_force("mb-test-other")
    local b = H.block(o, 4, 4, H.TIER)
    H.put(o, 3, 4, H.BELT, D.east, { force = other })
    H.put(o, 2, 4, H.BELT, D.east, { force = other })
    H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local rec = rec_of(b)
    assert(#rec.inputs == 0, "the other force's belt became an input")
    local t = H.at(o, 3, 4, "transport-belt")
    assert(t and t.force == other, "the other force's belt was swapped")
    local refused = false
    for _, r in ipairs(rec.refused) do
      refused = refused or r.reason == "other-force"
    end
    assert(refused, "not refused: " .. serpent.line(rec.refused))
  end)

  -- Final review Minor 2: the items on a block-tile interface of a group destroyed with nobody
  -- mining it are spilled off the block's tile, marked for the force's robots.
  test("block_tile_port_items_spilled_off_the_tile", function()
    async(900)
    local o, box = area(12, 12)
    local stock = 300
    local b = H.block(o, 5, 5, H.TIER)
    local ug = "express-underground-belt"
    H.put(o, 5, 2, ug, D.south, { type = "input" })
    H.put(o, 5, 4, ug, D.south, { type = "output" })
    H.put(o, 5, 1, "mb-test-loader-" .. H.TIER, D.south, { type = "output" })
    H.put(o, 5, 0, "mb-test-chest").insert({ name = ITEM, count = stock })
    local out = H.sink(o, 5, 5, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(600, function()
      local rec = rec_of(b)
      local lb = assert(rec.inputs[1] and rec.inputs[1].visible, "no block-tile interface")
      if H.items_on(lb) == 0 then
        error("test setup: the interface is empty")
      end
      local pos = b.position
      b.destroy({ raise_destroy = true })
      balancer.flush()
      assert(not lb.valid, "the interface is still there")
      assert(ground_on(pos.x, pos.y) == 0, ground_on(pos.x, pos.y) .. " items spilled on the block's tile")
      for _, it in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "item-entity" })) do
        assert(it.to_be_deconstructed(), "a spilled stack is not marked for the robots")
      end
      assert(H.count_box(box, ITEM) == stock, "after: " .. H.count_box(box, ITEM) .. " of " .. stock)
      done()
    end)
  end)

  -- Final review Minor 6: a block-tile linked belt cloned onto a tile no port claims is removed
  -- at the next flush, its items kept.
  test("cloned_block_tile_belt_cleaned_up", function()
    local o, box = area(10, 9)
    local s = game.surfaces.nauvis
    local lb = H.ce(s, { name = "mb-hidden-linked-belt-" .. H.TIER, position = { o.x + 2, o.y + 2 }, direction = D.east, type = "input" })
    lb.get_transport_line(1).insert_at(0.25, { name = ITEM, count = 1 })
    local clone = assert(lb.clone({ position = { o.x + 6, o.y + 6 } }), "no clone")
    lb.destroy()
    assert(clone.valid and balancer.pending(storage.balancer), "the clone is not loose")
    balancer.flush()
    assert(not clone.valid, "the cloned linked belt was left behind")
    assert(H.count_box(box, ITEM) == 1, "its item: " .. H.count_box(box, ITEM))
  end)

  -- Review Focus 3. A running 2:3 balancer (one input through a wired belt, Ruling 7) is
  -- blueprinted with its loaders and chests. The blueprint holds blocks and plain belts only (the
  -- edges are rewritten to the belts they replaced; the block-tile linked belt is not
  -- blueprintable) and the wired belt keeps its wire. Pasted elsewhere and built, it is a working
  -- 2:3: three equal outputs of 30 items/s.
  test("blueprint_round_trip", function()
    async(WARMUP + WINDOW + 600)
    local o, box = area(12, 9)
    H.block(o, 5, 0, H.TIER)
    H.block(o, 5, 1, H.TIER)
    H.feed(o, 5, 0, D.west, 3)
    local wired = H.feed(o, 5, 1, D.west, 3)
    local red = defines.wire_connector_id.circuit_red
    assert(wired.belts[1].get_wire_connector(red, true).connect_to(wired.belts[2].get_wire_connector(red, true)), "test setup: no wire")
    H.sink(o, 5, 0, D.east, 3)
    H.sink(o, 5, 1, D.east, 3)
    H.sink(o, 5, 1, D.south, 3)
    balancer.flush()
    local rec = rec_of(blocks_in(box)[1])
    assert(nm(rec) == "2:3", "source network " .. nm(rec))
    assert(#ours_in(box) == 5, "source: " .. #ours_in(box) .. " edges / block-tile belts, expected 4 edges + 1 block-tile belt")

    local bp, inv = blueprint_of({ { o.x - 0.5, o.y - 0.5 }, { o.x + 10.5, o.y + 6.5 } })
    -- before the rewrite, a raw blueprint records the edges (docs/feasibility.md F1)
    local raw_edges = 0
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      if be.name:sub(1, 8) == "mb-edge-" then
        raw_edges = raw_edges + 1
      end
    end
    assert(raw_edges == 4, "raw blueprint has " .. raw_edges .. " edges, expected 4")
    lifecycle.on_player_setup_blueprint({ player_index = nil, stack = bp })
    local names, wires = {}, 0
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      assert(be.name:sub(1, 3) ~= "mb-" or groups.tier_of(be.name), "blueprint holds " .. be.name)
      assert(be.type == nil or be.name:find("loader"), be.name .. " keeps a linked belt type")
      names[be.name] = (names[be.name] or 0) + 1
      wires = wires + #(be.wires or {})
    end
    assert(names["mb-balancer-" .. H.TIER] == 2, "blueprint blocks: " .. serpent.line(names))
    assert(names[H.BELT] == 15, "blueprint belts: " .. serpent.line(names))
    assert(wires >= 1, "the wire was lost")

    local o2, box2 = area(12, 9)
    local n = paste(bp, { o2.x + 5, o2.y + 3 }, box2)
    inv.destroy()
    assert(n == 17, n .. " ghosts revived, expected 2 blocks and 15 belts")
    local pasted = blocks_in(box2)
    assert(#pasted == 2, #pasted .. " blocks pasted")
    local p = origin_of(pasted[1], 5, 0)
    source(p, 1, 0, D.east)
    source(p, 1, 1, D.east)
    local sinks = { drain(p, 9, 0, D.east), drain(p, 9, 1, D.east), drain(p, 5, 5, D.south) }
    balancer.flush()
    local rec2 = rec_of(pasted[1])
    assert(nm(rec2) == "2:3", "pasted network " .. nm(rec2))
    assert(#ours_in(box2) == 5, "pasted: " .. #ours_in(box2) .. " edges / block-tile belts, expected 5")
    local wired_pasted = 0
    for _, b in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box2, type = "transport-belt" })) do
      local wc = b.get_wire_connector(red, true)
      if wc and wc.connection_count > 0 then
        wired_pasted = wired_pasted + 1
      end
    end
    assert(wired_pasted == 2, "pasted wired belts: " .. wired_pasted .. ", expected 2 (never swapped)")
    H.measure(function()
      local c = {}
      for i, ch in ipairs(sinks) do
        c[i] = ch.get_item_count()
      end
      return c
    end, WARMUP, WINDOW, function(rates)
      H.report("blueprint_round_trip: pasted outputs %s", serpent.line(rates))
      for j, v in ipairs(rates) do
        near(v, 2 * RATE / 3, "pasted output " .. j)
      end
      done()
    end)
  end)

  -- Copy-paste goes through the same event (on_player_setup_blueprint with the cursor's stack).
  -- A blueprint made before the rewrite (an old blueprint, or another mod's) still pastes: its edge
  -- ghosts become belt ghosts as they are placed. Both pastes are working 1:2 balancers.
  test("copy_paste_round_trip", function()
    async(1500)
    local o, box = area(9, 7)
    H.block(o, 4, 2, H.TIER)
    H.feed(o, 4, 2, D.west, 2)
    H.sink(o, 4, 2, D.east, 2)
    H.sink(o, 4, 2, D.south, 2)
    balancer.flush()
    local bbox = { { o.x - 0.5, o.y + 1.5 }, { o.x + 8.5, o.y + 6.5 } }
    local copy, inv1 = blueprint_of(bbox)
    local old, inv2 = blueprint_of(bbox)
    lifecycle.on_player_setup_blueprint({ player_index = nil, stack = copy })
    for _, be in ipairs(copy.get_blueprint_entities() or {}) do
      assert(be.name:sub(1, 8) ~= "mb-edge-", "the copy holds " .. be.name)
    end
    local results = {}
    for k, bp in ipairs({ copy, old }) do
      local o2, box2 = area(9, 7)
      local s = game.surfaces.nauvis
      bp.build_blueprint({ surface = s, force = "player", position = { o2.x + 4, o2.y + 4 }, build_mode = defines.build_mode.forced, raise_built = true })
      for _, g in ipairs(s.find_entities_filtered({ area = box2, type = "entity-ghost" })) do
        assert(g.ghost_name:sub(1, 8) ~= "mb-edge-", "paste " .. k .. ": an edge ghost " .. g.ghost_name .. " was placed")
      end
      revive_all(box2)
      local b = assert(blocks_in(box2)[1], "paste " .. k .. ": no block")
      local p = origin_of(b, 4, 2)
      source(p, 1, 2, D.east, 2000)
      local outs = { { chest = drain(p, 7, 2, D.east) }, { chest = drain(p, 4, 5, D.south) } }
      balancer.flush()
      local rec = rec_of(b)
      assert(nm(rec) == "1:2", "paste " .. k .. ": network " .. nm(rec))
      results[k] = outs
    end
    inv1.destroy()
    inv2.destroy()
    after_ticks(1200, function()
      for k, outs in ipairs(results) do
        local a, b = outs[1].chest.get_item_count(), outs[2].chest.get_item_count()
        assert(a > 200 and b > 200, "paste " .. k .. ": delivered " .. a .. " / " .. b)
      end
      done()
    end)
  end)

  -- Review Focus 4. A block whose neighbours are edges is deconstructed (its belts come back
  -- with their items, its network's items are spilled: nobody mined it), then the undo rebuilds
  -- the block from its ghost: the edges come back and the balancer runs again, nothing lost. The
  -- undo of mining an edge leaves an edge ghost, which becomes a belt ghost; the undo of building
  -- a belt that is now an edge marks the edge for deconstruction.
  test("undo_deconstruct", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 600
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out) -- backed up: full edges and a full network
    balancer.flush()
    after_ticks(600, function()
      assert(H.count_box(box, ITEM) == stock, "before: " .. H.count_box(box, ITEM))
      local s = game.surfaces.nauvis
      local pos = b.position
      b.destroy({ raise_destroy = true })
      balancer.flush()
      assert(H.at(o, 3, 4, "transport-belt") and H.at(o, 5, 4, "transport-belt"), "belts not restored")
      assert(#ours_in(box) == 0, "edges left after the removal")
      assert(H.count_box(box, ITEM) == stock, "after the removal: " .. H.count_box(box, ITEM))
      -- undo: the game places the block's ghost; the ghost is built
      local ghost = H.ce(s, { name = "entity-ghost", inner_name = "mb-balancer-" .. H.TIER, position = pos, raise_built = true })
      lifecycle.on_undo_redo({ player_index = 0, actions = { { type = "removed-entity", surface_index = s.index, target = { entity_number = 1, name = "mb-balancer-" .. H.TIER, position = pos } } } }, true)
      -- the network's items were spilled off the block's tile (fix round 1, I2), so a script
      -- revive there (which deletes colliding items without an `overflow`) deletes nothing
      local on_tile = s.find_entities_filtered({ area = { { pos.x - 0.5, pos.y - 0.5 }, { pos.x + 0.5, pos.y + 0.5 } }, type = "item-entity" })
      assert(#on_tile == 0, #on_tile .. " spilled stacks on the block's tile")
      local _, nb = ghost.revive({ raise_revive = true })
      assert(nb and groups.of(nb.unit_number), "the rebuilt block has no group")
      balancer.flush()
      local rec = rec_of(nb)
      assert(nm(rec) == "1:1", "after the undo: network " .. nm(rec))
      local ein = H.at(o, 3, 4, "linked-belt")
      assert(ein and ein.name == "mb-edge-in-" .. H.BELT and H.at(o, 5, 4, "linked-belt"), "edges not swapped again")
      assert(H.count_box(box, ITEM) == stock, "after the undo: " .. H.count_box(box, ITEM))

      -- undo of mining an edge: its ghost becomes a belt ghost, which builds an edge again
      local inv = game.create_inventory(10)
      local epos = ein.position
      assert(ein.mine({ inventory = inv, raise_destroyed = true }), "edge not mined")
      balancer.flush()
      local eg = s.create_entity({ name = "entity-ghost", inner_name = "mb-edge-in-" .. H.BELT, position = epos, direction = D.east, force = "player", type = "input", raise_built = true })
      assert(not (eg and eg.valid), "the edge ghost was kept")
      local bg = s.find_entities_filtered({ position = epos, type = "entity-ghost" })[1]
      assert(bg and bg.ghost_name == H.BELT and bg.direction == D.east, "no belt ghost in its place")
      -- the same through on_undo_applied (a ghost placed without a build event)
      bg.destroy()
      local eg2 = H.ce(s, { name = "entity-ghost", inner_name = "mb-edge-in-" .. H.BELT, position = epos, direction = D.east, type = "input" })
      lifecycle.on_undo_redo({ player_index = 0, actions = { { type = "removed-entity", surface_index = s.index, target = { entity_number = 1, name = "mb-edge-in-" .. H.BELT, position = epos, direction = D.east } } } }, true)
      assert(not eg2.valid, "on_undo_applied kept the edge ghost")
      bg = assert(s.find_entities_filtered({ position = epos, type = "entity-ghost" })[1], "no belt ghost after on_undo_applied")
      bg.revive({ raise_revive = true })
      for i = 1, #inv do
        if inv[i].valid_for_read and inv[i].name == ITEM then
          s.spill_item_stack({ position = epos, stack = inv[i] --[[@as LuaItemStack]], allow_belts = false })
        end
      end
      inv.destroy()
      balancer.flush()
      local ein2 = H.at(o, 3, 4, "linked-belt")
      assert(ein2 and ein2.name == "mb-edge-in-" .. H.BELT, "the rebuilt belt is not an edge")
      assert(nm(rec_of(nb)) == "1:1", "after rebuilding the edge: " .. nm(rec_of(nb)))
      -- undo of building the belt that became this edge: the edge is marked for deconstruction
      lifecycle.on_undo_redo({ player_index = 0, actions = { { type = "built-entity", surface_index = s.index, target = { entity_number = 1, name = H.BELT, position = epos, direction = D.east } } } }, true)
      assert(ein2.to_be_deconstructed(), "undo of the belt build did not mark the edge")
      ein2.cancel_deconstruction("player")
      release(out)
      local before = delivered({ out })
      after_ticks(600, function()
        assert(delivered({ out }) > before + 100, "the balancer does not run after the undo")
        done()
      end)
    end)
  end)

  -- Redo of the deconstruction: the block is marked again and a construction robot mines it. Its
  -- belts come back with their items, and its network's items go to the robot's logistic network
  -- (Task 4 M9): nothing on the ground at the block, the storage chest gets them all.
  test("redo", function()
    async(4000)
    local o, box = area(14, 10)
    local stock = 400
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    local _, chest = robots(o, 4, 8)
    balancer.flush()
    after_ticks(600, function()
      local rec = rec_of(b)
      local in_net = H.network_of(groups.of(b.unit_number))
      assert(in_net > 10, "test setup: only " .. in_net .. " items in the network")
      assert(H.count_box(box, ITEM) == stock, "before: " .. H.count_box(box, ITEM))
      assert(rec.placed, "no network")
      assert(b.order_deconstruction("player"), "the block cannot be marked for deconstruction")
      wait_for("robot mining the block", 60, function()
        return not b.valid
      end, function()
        after_ticks(2, function()
          assert(H.at(o, 3, 4, "transport-belt") and H.at(o, 5, 4, "transport-belt"), "belts not restored")
          local ground = 0
          for _, it in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "item-entity" })) do
            if it.stack.name == ITEM then
              ground = ground + it.stack.count
            end
          end
          local got = chest.get_item_count(ITEM)
          H.report("redo: %d in the network, %d to the storage chest, %d on the ground", in_net, got, ground)
          assert(got >= in_net, "the robot's network got " .. got .. " of " .. in_net)
          -- (H.count_box counts containers; the storage chest is a logistic container)
          local total = H.count_box(box, ITEM) + got
          assert(total == stock, string.format("after the robot mined the block: %d (network had %d, chest %d, ground %d)",
            total, in_net, got, ground))
          assert(ground == 0, ground .. " items on the ground")
          done()
        end)
      end)
    end)
  end)

  -- A ghost of a block between a waiting input and output is built by a construction robot
  -- (on_robot_built_entity): the belts become edges and the balancer runs.
  test("ghost_block_then_built_by_robot", function()
    async(3000)
    local o, box = area(14, 10)
    local s = game.surfaces.nauvis
    H.feed(o, 4, 4, D.west, 3, { stock = 2000 })
    local out = H.sink(o, 4, 4, D.east, 3)
    local _, chest = robots(o, 4, 8)
    chest.insert({ name = "mb-balancer-" .. H.TIER, count = 2 })
    H.ce(s, { name = "entity-ghost", inner_name = "mb-balancer-" .. H.TIER, position = { o.x + 4, o.y + 4 }, raise_built = true })
    ---@type LuaEntity?
    local found
    wait_for("robot building the block", 60, function()
      found = s.find_entities_filtered({ area = box, name = "mb-balancer-" .. H.TIER })[1]
      return found ~= nil
    end, function()
      local b = assert(found, "no block")
      assert(groups.of(b.unit_number), "the robot-built block has no group")
      balancer.flush()
      local rec = rec_of(b)
      assert(nm(rec) == "1:1", "network " .. nm(rec))
      after_ticks(600, function()
        assert(delivered({ out }) > 200, "only " .. delivered({ out }) .. " delivered")
        done()
      end)
    end)
  end)

  -- The upgrade planner on a block: a backed-up basic block marked for fast and upgraded (as a
  -- robot would: apply_upgrade raises destroy and built). The fast block joins a group (no overlap
  -- refusal), the network is rebuilt at the fast tier with every item, and it runs. The same
  -- through a fast-replace build (create_entity fast_replace).
  test("upgrade_planner_block_tier", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 500
    local b = H.block(o, 4, 4, "basic")
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(600, function()
      local in_net = H.network_of(groups.of(b.unit_number))
      assert(in_net > 20, "test setup: only " .. in_net .. " items in the basic network")
      assert(H.count_box(box, ITEM) == stock, "before: " .. H.count_box(box, ITEM))
      assert(b.order_upgrade({ target = "mb-balancer-fast", force = "player" }), "the block cannot be marked for upgrade")
      local nb = b.apply_upgrade()
      assert(nb and nb.valid and nb.name == "mb-balancer-fast", "not upgraded")
      local id = groups.of(nb.unit_number)
      local g = groups.get(id)
      assert(g and g.tier == "fast", "the upgraded block joined no fast group")
      balancer.flush()
      local rec = rec_of(nb)
      assert(nm(rec) == "1:1" and rec.placed and rec.placed.tier == "fast", "network " .. nm(rec) .. " tier " .. tostring(rec.placed and rec.placed.tier))
      assert(H.network_of(id) == in_net, "network items " .. H.network_of(id) .. " of " .. in_net)
      assert(H.count_box(box, ITEM) == stock, "after the upgrade: " .. H.count_box(box, ITEM))
      -- fast-replace build of an express block over it
      local s = game.surfaces.nauvis
      local eb = s.create_entity({ name = "mb-balancer-express", position = nb.position, force = "player", fast_replace = true, raise_built = true, spill = false })
      assert(eb and eb.valid, "fast replace refused")
      local eg = groups.get(groups.of(eb.unit_number))
      assert(eg and eg.tier == "express", "the fast-replaced block joined no express group")
      after_ticks(2, function()
        balancer.flush()
        local rec2 = rec_of(eb)
        assert(nm(rec2) == "1:1" and rec2.placed.tier == "express", "after fast replace: " .. nm(rec2))
        assert(H.count_box(box, ITEM) == stock, "after the fast replace: " .. H.count_box(box, ITEM))
        release(out)
        after_ticks(600, function()
          assert(delivered({ out }) > 100, "the upgraded balancer does not run")
          assert(H.count_box(box, ITEM) == stock, "at the end: " .. H.count_box(box, ITEM))
          done()
        end)
      end)
    end)
  end)

  -- The upgrade planner on a belt line into a block: marking the belt behind the edge also
  -- marks the edge's tile (swapped back to its belt, same order); it is not a port until it is
  -- upgraded; once the robots (apply_upgrade) upgrade the line it is an edge of the new belt.
  -- Items are kept throughout.
  test("upgrade_planner_on_edge_belt", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 300
    local b = H.block(o, 4, 4, H.TIER)
    local feed = H.feed(o, 4, 4, D.west, 3, { stock = stock, belt = "fast-transport-belt" })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(300, function()
      local edge = H.at(o, 3, 4, "linked-belt")
      assert(edge and edge.name == "mb-edge-in-fast-transport-belt", "no fast input edge")
      assert(H.count_box(box, ITEM) == stock, "before: " .. H.count_box(box, ITEM))
      local behind = feed.belts[2] --[[@as LuaEntity]]
      assert(behind.order_upgrade({ target = "express-transport-belt", force = "player" }), "belt not marked")
      local tile = H.at(o, 3, 4, "transport-belt")
      assert(tile and tile.name == "fast-transport-belt", "the edge was not swapped back to its belt")
      local target = tile.get_upgrade_target()
      assert(target and target.name == "express-transport-belt", "the edge's belt did not get the upgrade order")
      balancer.flush()
      assert(H.at(o, 3, 4, "transport-belt"), "a belt marked for upgrade was swapped")
      assert(#rec_of(b).inputs == 0, "a belt marked for upgrade counts as an input")
      for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "transport-belt" })) do
        if e.valid and e.to_be_upgraded() then
          e.apply_upgrade()
        end
      end
      balancer.flush()
      local e2 = H.at(o, 3, 4, "linked-belt")
      assert(e2 and e2.name == "mb-edge-in-express-transport-belt", "the upgraded tile is not an express edge: " .. tostring(e2 and e2.name))
      assert(nm(rec_of(b)) == "1:1", "network " .. nm(rec_of(b)))
      assert(H.count_box(box, ITEM) == stock, "after the upgrade: " .. H.count_box(box, ITEM))
      -- undo of that upgrade (UndoRedoAction upgraded-entity): the game finds no express belt on
      -- the edge's tile, so the edge goes back to its belt with the order back to fast
      local s = game.surfaces.nauvis
      lifecycle.on_undo_redo({ player_index = 0, actions = { { type = "upgraded-entity", surface_index = s.index, original_name = "fast-transport-belt",
        original_quality_name = "normal", target = { entity_number = 1, name = "express-transport-belt", position = e2.position, direction = D.east } } } }, true)
      local back = H.at(o, 3, 4, "transport-belt")
      local bt = back and back.get_upgrade_target()
      assert(back and back.name == "express-transport-belt" and bt and bt.name == "fast-transport-belt", "undo of the upgrade did not order the edge's tile back to fast")
      back.apply_upgrade()
      balancer.flush()
      local e3 = H.at(o, 3, 4, "linked-belt")
      assert(e3 and e3.name == "mb-edge-in-fast-transport-belt", "after the undone upgrade: " .. tostring(e3 and e3.name))
      assert(H.count_box(box, ITEM) == stock, "after the undo: " .. H.count_box(box, ITEM))
      release(out)
      after_ticks(600, function()
        assert(delivered({ out }) > 100, "does not run after the upgrade")
        done()
      end)
    end)
  end)

  -- Mining an edge gives its belt item and the items on it; the balancer drops that port. A
  -- deconstruction planner's marks survive the swaps: an edge marked with its block is a belt
  -- still marked once the block is gone.
  test("mine_edge_returns_belt_and_items", function()
    async(900)
    local o, box = area(10, 9)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 400 })
    H.feed(o, 4, 4, D.north, 3, { stock = 400 })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(600, function()
      assert(nm(rec_of(b)) == "2:1", "network " .. nm(rec_of(b)))
      local edge = assert(H.at(o, 3, 4, "linked-belt"), "no input edge")
      local on = H.items_on(edge)
      assert(on > 0, "test setup: the edge is empty")
      local inv = game.create_inventory(10)
      assert(edge.mine({ inventory = inv, raise_destroyed = true }), "not mined")
      assert(inv.get_item_count(H.BELT) == 1, "belt items: " .. inv.get_item_count(H.BELT))
      assert(inv.get_item_count(ITEM) == on, "items: " .. inv.get_item_count(ITEM) .. " of " .. on)
      assert(inv.get_item_count() == on + 1, "other items in the mined result")
      inv.destroy()
      balancer.flush()
      assert(nm(rec_of(b)) == "1:1", "after mining the edge: " .. nm(rec_of(b)))
      -- deconstruction marks follow the swaps
      local north = assert(H.at(o, 4, 3, "linked-belt"), "no north edge")
      assert(north.order_deconstruction("player") and b.order_deconstruction("player"), "cannot mark")
      b.destroy({ raise_destroy = true })
      balancer.flush()
      local belt = H.at(o, 4, 3, "transport-belt")
      assert(belt and belt.to_be_deconstructed(), "the restored belt lost its deconstruction mark")
      done()
    end)
  end)

  -- An edge built by the game rather than by the mod (a ghost of an old blueprint revived, a
  -- clone, another mod's script) away from any block is swapped back to its belt with its
  -- items; one pointing into a block is claimed as that block's port.
  test("edge_built_by_the_game", function()
    local o = area(10, 9)
    local s = game.surfaces.nauvis
    local stray = H.ce(s, { name = "mb-edge-in-" .. H.BELT, position = { o.x + 1, o.y + 1 }, direction = D.east, type = "input", raise_built = true })
    stray.get_transport_line(1).insert_at(0.25, { name = ITEM, count = 1 })
    -- no block near it: nothing is dirty, but the flush has work (I1): on_load must re-arm here
    assert(next(storage.balancer.dirty) == nil, "test setup: a group is dirty")
    assert(balancer.pending(storage.balancer), "a loose edge alone is not pending work")
    local b = H.block(o, 5, 5, H.TIER)
    H.sink(o, 5, 5, D.east, 2)
    local claimed = H.ce(s, { name = "mb-edge-in-" .. H.BELT, position = { o.x + 4, o.y + 5 }, direction = D.east, type = "input", raise_built = true })
    balancer.flush()
    local belt = H.at(o, 1, 1, "transport-belt")
    assert(belt and belt.name == H.BELT and not stray.valid, "the stray edge was not swapped back")
    assert(H.items_on(belt) == 1, "the stray edge's item was lost")
    assert(claimed.valid and claimed.linked_belt_neighbour, "the edge into the block was not claimed")
    assert(nm(rec_of(b)) == "1:1", "network " .. nm(rec_of(b)))
    -- the swaps re-check their neighbours once more (F3), then nothing is left
    for _ = 1, 3 do
      if balancer.pending(storage.balancer) then
        balancer.flush()
      end
    end
    assert(not balancer.pending(storage.balancer), "work left after the flushes")
  end)

  -- Fix round 1, I2: a backed-up group killed (biters, here LuaEntity::die) with ghosts on death
  -- and construction robots around. Nobody mined it, so its network's items are spilled, never on
  -- the group's tiles, marked for the force's robots. The robots pick them up and rebuild the
  -- blocks from their death ghosts: every item is accounted for, and the balancer runs again.
  test("destroyed_group_rebuilt_by_robots_keeps_items", function()
    async(5000)
    local o, box = area(14, 12)
    local s = game.surfaces.nauvis
    local force = game.forces.player
    local saved, saved_cargo = force.create_ghost_on_entity_death, force.worker_robots_storage_bonus
    force.create_ghost_on_entity_death = true
    force.worker_robots_storage_bonus = 10 -- researched cargo, so the pick-up does not take minutes
    local stock = 600
    local b1 = H.block(o, 4, 4, H.TIER)
    local b2 = H.block(o, 4, 5, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 5, D.east, 3)
    block(out)
    local _, chest = robots(o, 4, 10)
    chest.insert({ name = "mb-balancer-" .. H.TIER, count = 4 })
    balancer.flush()
    local function robot_items()
      local n = 0
      for _, r in ipairs(s.find_entities_filtered({ area = { { o.x - 80, o.y - 80 }, { o.x + 94, o.y + 92 } }, type = "construction-robot" })) do
        local cargo = r.get_inventory(defines.inventory.robot_cargo)
        n = n + (cargo and cargo.get_item_count(ITEM) or 0)
      end
      return n
    end
    local function total()
      return H.count_box(box, ITEM) + chest.get_item_count(ITEM) + robot_items()
    end
    after_ticks(600, function()
      local in_net = H.network_of(groups.of(b1.unit_number))
      assert(in_net > 10, "test setup: only " .. in_net .. " in the network")
      assert(total() == stock, "before: " .. total())
      local tiles = { { b1.position.x, b1.position.y }, { b2.position.x, b2.position.y } }
      b1.die()
      b2.die()
      balancer.flush()
      for _, t in ipairs(tiles) do
        local on = s.find_entities_filtered({ area = { { t[1] - 0.5, t[2] - 0.5 }, { t[1] + 0.5, t[2] + 0.5 } }, type = "item-entity" })
        assert(#on == 0, #on .. " spilled stacks on a block tile")
      end
      local spilled, marked = 0, 0
      for _, it in ipairs(s.find_entities_filtered({ area = box, type = "item-entity" })) do
        if it.stack.name == ITEM then
          spilled = spilled + it.stack.count
          if it.to_be_deconstructed() then
            marked = marked + it.stack.count
          end
        end
      end
      assert(spilled == in_net and marked == spilled, "spilled " .. spilled .. " (marked " .. marked .. ") of " .. in_net)
      assert(total() == stock, "after the deaths: " .. total())
      wait_for("robots rebuilding the blocks and collecting the items", 140, function()
        local blocks = s.find_entities_filtered({ area = box, name = "mb-balancer-" .. H.TIER })
        local ground = s.find_entities_filtered({ area = box, type = "item-entity" })
        return #blocks == 2 and #ground == 0 and robot_items() == 0,
          string.format("%d blocks, %d ground stacks, %d in robots, %d ghosts, chest %d; ground %s; block at %s", #blocks, #ground, robot_items(),
            #s.find_entities_filtered({ area = box, type = "entity-ghost" }), chest.get_item_count(ITEM),
            serpent.line((function()
              local l = {}
              for _, g in ipairs(ground) do
                l[#l + 1] = { g.stack.name, g.stack.count, g.position, g.to_be_deconstructed() }
              end
              return l
            end)()), serpent.line({ b1.valid }))
      end, function()
        force.create_ghost_on_entity_death = saved
        force.worker_robots_storage_bonus = saved_cargo
        balancer.flush()
        local list = blocks_in(box)
        local rec = rec_of(list[1])
        H.report("destroyed_group_rebuilt_by_robots: %d spilled, chest %d, total %d of %d", in_net, chest.get_item_count(ITEM), total(), stock)
        assert(total() == stock, "after the robots: " .. total() .. " of " .. stock)
        assert(chest.get_item_count(ITEM) == in_net, "the robots collected " .. chest.get_item_count(ITEM) .. " of " .. in_net)
        assert(nm(rec) == "1:1", "rebuilt network " .. nm(rec))
        done()
      end)
    end)
  end)

  -- Fix round 1, M3: without Space Age, a leftover turbo block item or ghost placed later becomes
  -- an express block or ghost (only checked in vanilla, where turbo is orphaned).
  test("leftover_orphan_tier_block_is_replaced", function()
    ---@diagnostic disable-next-line: unnecessary-if
    if script.active_mods["space-age"] then
      return
    end
    local o = area(6, 6)
    local s = game.surfaces.nauvis
    s.create_entity({ name = "mb-balancer-turbo", position = { o.x + 2, o.y + 2 }, force = "player", raise_built = true })
    local e = H.at(o, 2, 2, "simple-entity-with-owner")
    assert(e and e.name == "mb-balancer-express" and groups.of(e.unit_number), "the turbo block was not replaced by a grouped express block")
    s.create_entity({ name = "entity-ghost", inner_name = "mb-balancer-turbo", position = { o.x + 4, o.y + 2 }, force = "player", raise_built = true })
    local g = H.at(o, 4, 2, "entity-ghost")
    assert(g and g.ghost_name == "mb-balancer-express", "the turbo ghost was not replaced: " .. tostring(g and g.ghost_name))
  end)

  -- Fix round 1, M2: a space platform that mines the last block gets the network's items in its
  -- hub (Space Age only; give() is driven directly with a platform sink).
  test("platform_sink_gets_items", function()
    ---@diagnostic disable-next-line: unnecessary-if
    if not script.active_mods["space-age"] then
      return
    end
    local p = game.forces.player.create_space_platform({ name = "mb-test-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack" })
    assert(p, "no platform")
    p.apply_starter_pack()
    local hub = assert(p.hub, "no hub")
    local inv = game.create_inventory(2)
    inv.insert({ name = ITEM, count = 150 })
    local before = hub.get_item_count(ITEM)
    balancer.give(inv, { platform = p }, p.surface, hub.position, {}, nil)
    assert(hub.get_item_count(ITEM) - before == 150, "hub got " .. (hub.get_item_count(ITEM) - before) .. " of 150")
    p.destroy()
  end)

  -- Rotating a belt next to a block (a passing belt turned into it becomes an input; an input
  -- edge turned round becomes an output, turned sideways a plain belt again) and flipping a
  -- splitter that feeds a block: ports follow, nothing is lost.
  test("rotate_and_flip_neighbour_belt", function()
    local o, box = area(10, 9)
    local stock = 200
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    local passing = H.put(o, 4, 5, H.BELT, D.east)
    balancer.flush()
    assert(nm(rec_of(b)) == "1:1", "start " .. nm(rec_of(b)))
    -- east -> north: points into the block
    passing.rotate({ reverse = true })
    assert(passing.direction == D.north, "test setup: rotated to " .. passing.direction)
    events.on_rotated({ entity = passing })
    balancer.flush()
    local e = H.at(o, 4, 5, "linked-belt")
    assert(e and e.name == "mb-edge-in-" .. H.BELT, "the rotated belt is not an input edge")
    assert(nm(rec_of(b)) == "2:1", "after rotating in: " .. nm(rec_of(b)))
    -- the edge turned round (north -> south): an output
    e.rotate()
    e.rotate()
    events.on_rotated({ entity = e })
    balancer.flush()
    local e2 = H.at(o, 4, 5, "linked-belt")
    assert(e2 and e2.name == "mb-edge-out-" .. H.BELT and e2.direction == D.south, "not an output edge facing south")
    assert(nm(rec_of(b)) == "1:2", "after turning round: " .. nm(rec_of(b)))
    -- sideways (south -> west): a plain belt again
    e2.rotate()
    events.on_rotated({ entity = e2 })
    balancer.flush()
    local plain = H.at(o, 4, 5, "transport-belt")
    assert(plain and plain.direction == D.west and not H.at(o, 4, 5, "linked-belt"), "not a plain belt facing west")
    assert(nm(rec_of(b)) == "1:1", "after turning sideways: " .. nm(rec_of(b)))
    -- a splitter feeding the block from the north (block-tile interface), flipped
    local sp = H.put(o, 4.5, 3, "express-splitter", D.south)
    balancer.flush()
    assert(nm(rec_of(b)) == "2:1", "with the splitter: " .. nm(rec_of(b)))
    local flipped = sp.flip({ horizontal = true })
    events.on_flipped({ entity = sp, horizontal = true })
    balancer.flush()
    assert(nm(rec_of(b)) == "2:1", "after the flip (" .. tostring(flipped) .. "): " .. nm(rec_of(b)))
    assert(H.count_box(box, ITEM) == stock, "items: " .. H.count_box(box, ITEM) .. " of " .. stock)
  end)

  -- Review Focus 5 in the running game: the blocks of a tier are replaced by another tier's
  -- (lifecycle.downgrade, which on_configuration_changed runs for a tier whose belt is gone; the
  -- real Space Age removal is the MCP check in docs/feasibility.md). Every item of the old
  -- networks moves into the new tier's network, and the balancer runs.
  test("space_age_removed", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 500
    local b1 = H.block(o, 4, 4, H.TIER)
    H.block(o, 4, 5, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 5, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(600, function()
      local in_net = H.network_of(groups.of(b1.unit_number))
      assert(in_net > 20, "test setup: only " .. in_net .. " in the network")
      local n = lifecycle.downgrade({ [H.TIER] = true }, "fast")
      assert(n == 2, n .. " blocks replaced")
      local list = blocks_in(box)
      assert(#list == 2 and list[1].name == "mb-balancer-fast" and list[2].name == "mb-balancer-fast", "blocks not replaced")
      balancer.flush()
      local rec, id = rec_of(list[1])
      assert(nm(rec) == "1:1" and rec.placed.tier == "fast", "network " .. nm(rec))
      assert(H.network_of(id) == in_net, "network items " .. H.network_of(id) .. " of " .. in_net)
      assert(H.count_box(box, ITEM) == stock, "after the downgrade: " .. H.count_box(box, ITEM))
      release(out)
      after_ticks(600, function()
        assert(delivered({ out }) > 100, "does not run after the downgrade")
        done()
      end)
    end)
  end)

  -- A changed belt speed reaches the hidden networks through their prototypes (built in
  -- data-final-fixes from the final belts, F9); the configuration change only refreshes every
  -- group, which changes nothing in a balancer whose ports are unchanged. (The save loaded with
  -- a speed mod added is the MCP check in docs/feasibility.md.)
  test("belt_speed_changed_by_mod", function()
    local o, box = area(10, 9)
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = 100 })
    H.sink(o, 4, 4, D.east, 3)
    balancer.flush()
    local rec = rec_of(b)
    local placed = rec.placed
    for _, e in ipairs(placed.entities) do
      if e.valid and e.type ~= "container" then
        assert(e.prototype.belt_speed == prototypes.entity[H.BELT].belt_speed, e.name .. " speed differs from its belt")
      end
    end
    assert(#builder.speed_mismatches() == 0, "speed mismatches: " .. serpent.line(builder.speed_mismatches()))
    lifecycle.on_configuration_changed()
    balancer.flush()
    local rec2 = rec_of(b)
    assert(rec2.placed == placed, "a configuration change rebuilt an unchanged balancer")
    assert(H.count_box(box, ITEM) == 100, "items: " .. H.count_box(box, ITEM))
  end)

  -- Fix round 1, M6: the hidden surface cleared by someone else (LuaSurface::clear): the items
  -- are spilled first (on_pre_surface_cleared), the networks are placed again, nothing lost.
  test("hidden_surface_cleared", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 400
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(300, function()
      local hs = assert(game.get_surface(storage.surface_index --[[@as integer]]), "no hidden surface")
      hs.clear()
      after_ticks(3, function()
        balancer.flush()
        local rec = rec_of(b)
        assert(rec.placed and rec.placed.entities[1].valid, "no valid network after the clear")
        assert(nm(rec) == "1:1", "network " .. nm(rec))
        assert(H.count_box(box, ITEM) == stock, "after the clear: " .. H.count_box(box, ITEM))
        release(out)
        local before = delivered({ out })
        after_ticks(600, function()
          assert(delivered({ out }) > before + 100, "does not run after the clear")
          done()
        end)
      end)
    end)
  end)

  -- The hidden surface deleted by someone else: every network's items are spilled at its blocks
  -- first (on_pre_surface_deleted), a new hidden surface is made and every network placed again.
  -- Nothing is lost and the balancer runs. Last in this suite: it replaces the hidden surface.
  test("hidden_surface_deleted", function()
    async(1500)
    local o, box = area(10, 9)
    local stock = 400
    local b = H.block(o, 4, 4, H.TIER)
    H.feed(o, 4, 4, D.west, 3, { stock = stock })
    local out = H.sink(o, 4, 4, D.east, 3)
    block(out)
    balancer.flush()
    after_ticks(300, function()
      local old = assert(game.get_surface(storage.surface_index --[[@as integer]]), "no hidden surface")
      assert(game.delete_surface(old), "the hidden surface cannot be deleted")
      wait_for("surface deletion", 20, function()
        return not old.valid
      end, function()
        balancer.flush()
        local rec = rec_of(b)
        assert(rec.placed and rec.placed.entities[1].valid, "no new network")
        -- (the new surface may reuse the old index)
        assert(storage.surface_index and game.get_surface(storage.surface_index), "no new hidden surface")
        assert(nm(rec) == "1:1", "network " .. nm(rec))
        assert(H.count_box(box, ITEM) == stock, "after the deletion: " .. H.count_box(box, ITEM))
        release(out)
        local before = delivered({ out })
        after_ticks(600, function()
          assert(delivered({ out }) > before + 100, "does not run on the new surface")
          done()
        end)
      end)
    end)
  end)
end)
