-- Connected groups of visible balancer blocks (scripts/groups.lua, scripts/events.lua): blocks of
-- one tier and force that touch edge to edge form one group, built and removed through the
-- mod's events. Every test checks storage against a flood fill from scratch (H.check_groups).
-- Plain assert, not luassert.
local groups = require("scripts.groups")
local H = require("tests.game.harness")

local W = 12

-- A fresh area; returns its origin and box.
local function area()
  return H.area(W, W)
end

local function clear(box)
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box })) do
    if e.valid and e.type ~= "character" then
      e.destroy()
    end
  end
end

local function same(a, b)
  return serpent.line(a) == serpent.line(b)
end

---@type BoundingBox?
local last_box

-- Builds a block without raise_built and hands it to the groups directly, so the test sees the
-- `ids, gone` lists (registered for on_object_destroyed like events.lua does).
local function build_direct(o, dx, dy, tier, force)
  local e = H.ce(game.surfaces.nauvis, { name = "mb-balancer-" .. tier, position = { o.x + dx, o.y + dy }, force = force or "player" })
  script.register_on_object_destroyed(e)
  local ids, gone = groups.on_block_built(e)
  return e, ids, gone
end

local function force(name)
  return game.forces[name] or game.create_force(name)
end

describe("groups", function()
  after_each(function()
    if last_box then
      clear(last_box)
      last_box = nil
    end
  end)

  -- Entity, item and recipe per tier (turbo only with Space Age), the upgrade chain, the
  -- recipe, the unlock by the splitter's technology, and the F1 collision mask.
  test("prototypes_per_tier", function()
    local tiers = {
      { "basic", "splitter", "transport-belt" },
      { "fast", "fast-splitter", "fast-transport-belt" },
      { "express", "express-splitter", "express-transport-belt" },
      { "turbo", "turbo-splitter", "turbo-transport-belt" },
    }
    local sa = script.active_mods["space-age"] ~= nil
    for i, t in ipairs(tiers) do
      local name = "mb-balancer-" .. t[1]
      local e = prototypes.entity[name]
      if t[1] == "turbo" and not sa then
        assert(e == nil and prototypes.item[name] == nil and prototypes.recipe[name] == nil, "turbo exists without Space Age")
      else
        assert(e and e.type == "simple-entity-with-owner", name .. ": entity missing or wrong type")
        assert(e.tile_width == 1 and e.tile_height == 1, name .. ": not 1x1")
        local layers = e.collision_mask.layers
        assert(layers.item and layers.player and layers.is_object and not layers.transport_belt and not layers.object,
          name .. ": collision mask " .. serpent.line(layers))
        assert(prototypes.item[name] and prototypes.item[name].place_result == e, name .. ": item missing")
        local next_tier = tiers[i + 1]
        local want_next = next_tier and (next_tier[1] ~= "turbo" or sa) and ("mb-balancer-" .. next_tier[1]) or nil
        assert((e.next_upgrade and e.next_upgrade.name) == want_next, name .. ": next_upgrade " .. tostring(e.next_upgrade and e.next_upgrade.name))
        ---@diagnostic disable-next-line: unnecessary-assert
        local r = assert(prototypes.recipe[name], name .. ": recipe missing")
        local got = {}
        for _, ing in ipairs(r.ingredients) do
          got[ing.name] = ing.amount
        end
        assert(got[t[2]] == 1 and got[t[3]] == 5 and table_size(got) == 2, name .. ": ingredients " .. serpent.line(got))
        local unlocks_both = false
        for _, tech in pairs(prototypes.technology) do
          local has_splitter, has_block = false, false
          for _, eff in ipairs(tech.effects) do
            if eff.type == "unlock-recipe" then
              has_splitter = has_splitter or eff.recipe == t[2]
              has_block = has_block or eff.recipe == name
            end
          end
          unlocks_both = unlocks_both or (has_splitter and has_block)
        end
        assert(unlocks_both, name .. ": not unlocked by the technology of " .. t[2])
      end
    end
  end)

  test("single_block_is_a_group", function()
    local o, box = area()
    last_box = box
    local b = H.block(o, 0, 0, "express")
    local id = groups.of(b.unit_number)
    assert(id, "the block has no group")
    local g = assert(groups.get(id), "group " .. id .. " missing")
    assert(g.id == id and g.tier == "express" and g.surface_index == b.surface_index, "wrong group fields: " .. serpent.line(g))
    assert(g.force.name == "player", "wrong force " .. g.force.name)
    assert(table_size(g.blocks) == 1 and g.blocks[b.unit_number] == b, "group does not hold exactly the block")
    assert(same(H.check_groups(box, "single"), { 1 }), "expected one group of 1")
  end)

  test("row_of_eight_is_one_group", function()
    local o, box = area()
    last_box = box
    -- built from both ends towards the middle, so the last block merges two groups
    local row = {}
    for _, dx in ipairs({ 0, 7, 1, 6, 2, 5, 3 }) do
      row[dx] = H.block(o, dx, 0, "express")
    end
    local a = assert(groups.of(row[0].unit_number))
    local b = assert(groups.of(row[7].unit_number))
    local _, ids, gone = build_direct(o, 4, 0, "express")
    -- equal halves of 4: the lower id survives
    local keep, drop = math.min(a, b), math.max(a, b)
    assert(same(ids, { keep }) and same(gone, { drop }), "final merge reported " .. serpent.line({ ids, gone }) .. ", expected " .. serpent.line({ { keep }, { drop } }))
    assert(groups.get(drop) == nil, "the merged-away group still exists")
    assert(same(H.check_groups(box, "row"), { 8 }), "expected one group of 8: " .. serpent.line(H.check_groups(box, "row")))
  end)

  -- The user's example shape (spec Update 2), as read here: a column of 4, an arm of 3 to the
  -- east from its foot (an L), and a branch of 2 to the west from its second block. A block
  -- touching the top of the column only at a corner is a separate group.
  test("l_shape_and_branch_are_one_group", function()
    local o, box = area()
    last_box = box
    local shape = { { 3, 3 }, { 0, 0 }, { -2, 1 }, { 2, 3 }, { 0, 3 }, { 0, 1 }, { -1, 1 }, { 1, 3 }, { 0, 2 } }
    for _, p in ipairs(shape) do
      -- the event already added it; a second call changes nothing
      local ids, gone = groups.on_block_built(H.block(o, p[1] + 2, p[2] + 2, "fast"))
      assert(#ids == 0 and #gone == 0, "a block added twice reported a change")
    end
    assert(same(H.check_groups(box, "L"), { 9 }), "expected one group of 9: " .. serpent.line(H.check_groups(box, "L")))
    H.block(o, 3, 1, "fast") -- diagonal to the column top (2, 2)
    assert(same(H.check_groups(box, "L + corner"), { 9, 1 }), "a corner touch joined: " .. serpent.line(H.check_groups(box, "L + corner")))
  end)

  test("different_tiers_never_join", function()
    local o, box = area()
    last_box = box
    local a = H.block(o, 0, 0, "basic")
    local b = H.block(o, 1, 0, "fast")
    local c = H.block(o, 2, 0, "basic")
    local d = H.block(o, 3, 0, "express")
    local e = H.block(o, 0, 1, "fast")
    local ids = {}
    for _, x in ipairs({ a, b, c, d, e }) do
      local id = groups.of(x.unit_number)
      assert(id and not ids[id], "two blocks of different tiers share a group")
      ids[id] = true
    end
    assert(same(H.check_groups(box, "tiers"), { 1, 1, 1, 1, 1 }), "expected five groups of 1")
    -- another force never joins either
    local other = game.forces["mb-test-other"] or game.create_force("mb-test-other")
    local f = H.block(o, 0, 3, "basic")
    local g = H.block(o, 1, 3, "basic", other)
    assert(groups.of(f.unit_number) ~= groups.of(g.unit_number), "blocks of two forces share a group")
    assert(assert(groups.get(groups.of(g.unit_number))).force.name == "mb-test-other", "wrong force on the other group")
    H.check_groups(box, "forces")
  end)

  test("removing_middle_block_splits", function()
    local o, box = area()
    last_box = box
    local row = {}
    for dx = 0, 4 do
      row[dx] = H.block(o, dx, 0, "express")
    end
    local id = groups.of(row[0].unit_number)
    -- script-raised destroy of the middle block: two groups of 2
    local unit = row[2].unit_number
    row[2].destroy({ raise_destroy = true })
    assert(groups.of(unit) == nil, "the destroyed block still has a group")
    assert(same(H.check_groups(box, "split"), { 2, 2 }), "expected two groups of 2: " .. serpent.line(H.check_groups(box, "split")))
    assert(groups.get(id), "the original group id did not survive the split")
    -- building it again merges them back
    row[2] = H.block(o, 2, 0, "express")
    assert(same(H.check_groups(box, "merge"), { 5 }), "expected one group of 5 after rebuilding")
    -- a block that dies splits the same way
    row[1].die()
    assert(same(H.check_groups(box, "die"), { 3, 1 }), "expected 3 + 1 after a block died: " .. serpent.line(H.check_groups(box, "die")))
    -- removing the last block of a group removes the group
    local lone = groups.of(row[0].unit_number)
    row[0].destroy({ raise_destroy = true })
    assert(groups.get(lone) == nil, "an empty group was kept")
    -- a plus shape: removing the centre gives four groups
    local p = { x = o.x + 6, y = o.y + 6 }
    local centre = H.block(p, 0, 0, "basic")
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      H.block(p, d[1], d[2], "basic")
    end
    local ids, gone = groups.on_block_removed(centre)
    assert(#ids == 4 and #gone == 0, "plus split reported " .. serpent.line({ ids, gone }))
    centre.destroy() -- already removed above; on_object_destroyed then finds nothing to do
    assert(same(H.check_groups(box, "plus"), { 3, 1, 1, 1, 1 }), "plus: " .. serpent.line(H.check_groups(box, "plus")))
    -- building the centre again is a 4-way merge: one group left, three gone, the lowest id
    -- kept (all arms have one block)
    table.sort(ids)
    local _, ids2, gone2 = build_direct(p, 0, 0, "basic")
    assert(same(ids2, { ids[1] }), "4-way merge kept " .. serpent.line(ids2) .. ", expected " .. ids[1])
    table.sort(gone2)
    assert(same(gone2, { ids[2], ids[3], ids[4] }), "4-way merge gone " .. serpent.line(gone2))
    for _, id in ipairs(gone2) do
      assert(groups.get(id) == nil, "merged-away group " .. id .. " still exists")
    end
    assert(same(H.check_groups(box, "plus merged"), { 5, 3 }), "plus merged: " .. serpent.line(H.check_groups(box, "plus merged")))
  end)

  -- script_raised_teleported: a block moved next to a row joins it; one moved out of a row's
  -- middle splits the row and starts its own group.
  test("teleported_block_moves_between_groups", function()
    local o, box = area()
    last_box = box
    for dx = 0, 2 do
      H.block(o, dx, 0, "fast")
    end
    local lone = H.block(o, 6, 6, "fast")
    assert(same(H.check_groups(box, "before"), { 3, 1 }), "before teleport")
    assert(lone.teleport({ o.x + 3, o.y }, nil, true), "teleport refused")
    assert(same(H.check_groups(box, "joined"), { 4 }), "teleported block did not join: " .. serpent.line(H.check_groups(box, "joined")))
    local mid = assert(game.surfaces.nauvis.find_entities_filtered({ position = { o.x + 1, o.y }, name = "mb-balancer-fast" })[1])
    assert(mid.teleport({ o.x + 6, o.y + 6 }, nil, true), "teleport refused")
    assert(same(H.check_groups(box, "split"), { 2, 1, 1 }), "teleport out did not split: " .. serpent.line(H.check_groups(box, "split")))
  end)

  -- game.merge_forces moves blocks to the destination force without build events: the groups
  -- take the destination force, touching groups of the same tier merge, and a later build next
  -- to them works (the old LuaForce is invalid by then).
  test("forces_merged_regroups", function()
    local o, box = area()
    last_box = box
    local a, b = force("mb-test-merge-a"), force("mb-test-merge-b")
    local a_index = a.index
    H.block(o, 0, 0, "basic", a)
    H.block(o, 1, 0, "basic", b)
    H.block(o, 0, 1, "basic", a)
    H.block(o, 6, 6, "basic", a) -- an a-only group elsewhere
    H.block(o, 2, 0, "fast", b) -- another tier: never joins
    assert(same(H.check_groups(box, "before"), { 2, 1, 1, 1 }), "before merge: " .. serpent.line(H.check_groups(box, "before")))
    game.merge_forces(a, b)
    after_ticks(2, function()
      assert(game.forces["mb-test-merge-a"] == nil, "force a still exists")
      for _, g in pairs(storage.groups.by_id) do
        assert(g.force_index ~= a_index, "a group kept the merged-away force index")
      end
      assert(same(H.check_groups(box, "merged"), { 3, 1, 1 }), "after merge: " .. serpent.line(H.check_groups(box, "merged")))
      local e = H.block(o, 1, 1, "basic", b)
      local g = assert(groups.get(groups.of(e.unit_number)))
      assert(g.force.name == "mb-test-merge-b" and g.count == 4, "build after merge: " .. serpent.line({ g.force.name, g.count }))
      H.check_groups(box, "built after merge")
    end)
  end)

  -- Two blocks on one tile (create_entity does not check collisions): the second joins no group
  -- and the first keeps its place in the index.
  test("overlapping_block_is_refused", function()
    local o, box = area()
    last_box = box
    local first = H.block(o, 0, 0, "express")
    H.block(o, 1, 0, "express")
    local second = H.block(o, 0, 0, "express")
    assert(groups.of(second.unit_number) == nil, "the overlapping block joined a group")
    local id = assert(groups.of(first.unit_number), "the first block lost its group")
    assert(assert(groups.get(id)).count == 2, "the group changed")
    second.destroy({ raise_destroy = true })
    assert(groups.of(first.unit_number) == id and assert(groups.get(id)).count == 2, "removing the refused block changed the group")
    assert(same(H.check_groups(box, "overlap"), { 2 }), "overlap: " .. serpent.line(H.check_groups(box, "overlap")))
  end)

  test("robot_and_script_builds_count", function()
    local o, box = area()
    last_box = box
    local s = game.surfaces.nauvis
    -- script_raised_revive: a ghost revived by script
    H.block(o, 0, 0, "express")
    local ghost = H.ce(s, { name = "entity-ghost", inner_name = "mb-balancer-express", position = { o.x + 1, o.y } })
    local _, revived = ghost.revive({ raise_revive = true })
    assert(revived and groups.of(revived.unit_number), "a revived block has no group")
    assert(same(H.check_groups(box, "revive"), { 2 }), "revived block did not join")
    -- on_entity_cloned: a clone of the row next to it joins, a clone far away is its own group
    revived.clone({ position = { o.x + 2, o.y } })
    assert(same(H.check_groups(box, "clone"), { 3 }), "cloned block did not join")
    revived.clone({ position = { o.x + 6, o.y + 6 } })
    assert(same(H.check_groups(box, "clone far"), { 3, 1 }), "far clone: " .. serpent.line(H.check_groups(box, "clone far")))
    -- on_object_destroyed: destroyed without an event, the block leaves its group a tick later
    local far = assert(s.find_entities_filtered({ position = { o.x + 6, o.y + 6 }, name = "mb-balancer-express" })[1], "no far clone")
    local far_unit = far.unit_number
    local far_group = groups.of(far_unit)
    far.destroy()
    -- on_robot_built_entity: a construction robot builds a ghost next to the row
    local port = H.ce(s, { name = "mb-test-roboport", position = { o.x + 5, o.y + 3 } })
    port.get_inventory(defines.inventory.roboport_robot).insert({ name = "construction-robot", count = 5 })
    local chest = H.ce(s, { name = "storage-chest", position = { o.x + 10, o.y + 3 } })
    chest.insert({ name = "mb-balancer-express", count = 5 })
    H.ce(s, { name = "entity-ghost", inner_name = "mb-balancer-express", position = { o.x + 3, o.y } })
    local function wait(n)
      after_ticks(30, function()
        local built = s.find_entities_filtered({ position = { o.x + 3, o.y }, name = "mb-balancer-express" })[1]
        if built then
          assert(groups.of(far_unit) == nil and groups.get(far_group) == nil, "a block destroyed without an event kept its group")
          assert(groups.of(built.unit_number), "the robot-built block has no group")
          assert(same(H.check_groups(box, "robot"), { 4 }), "robot: " .. serpent.line(H.check_groups(box, "robot")))
          -- on_robot_mined_entity: a robot deconstructs the second block, the row splits 1 + 2
          local second = assert(s.find_entities_filtered({ position = { o.x + 1, o.y }, name = "mb-balancer-express" })[1], "no second block")
          local second_unit = second.unit_number
          second.order_deconstruction("player")
          local function wait_mined(k)
            after_ticks(30, function()
              if second.valid then
                assert(k > 0, "no robot mined the block in 1 800 ticks")
                wait_mined(k - 1)
              else
                assert(groups.of(second_unit) == nil, "the mined block still has a group")
                assert(same(H.check_groups(box, "robot mined"), { 2, 1 }), "robot mined: " .. serpent.line(H.check_groups(box, "robot mined")))
              end
            end)
          end
          wait_mined(60)
        else
          assert(n > 0, "no robot built the ghost in 1 800 ticks")
          wait(n - 1)
        end
      end)
    end
    wait(60)
  end)
end)
