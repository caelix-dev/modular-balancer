-- Per-balancer settings (Plan 3 Task 3, scripts/gui.lua): balance lanes and redistribute unused
-- shares. Toggling either on a running balancer rebuilds it with its items, the setting travels
-- with settings paste and blueprints, and a merge keeps the larger group's settings.
-- fdev test is headless and has no player, so the GUI's checkbox is driven through gui.set (what
-- the checkbox handler calls), settings paste through the mod's on_entity_settings_pasted
-- handler, and on_player_setup_blueprint as in tests/game/lifecycle.lua (with the mapping that
-- LuaItemCommon::create_blueprint returns). Express belts (45 items/s). Plain assert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")
local events = require("scripts.events")
local lifecycle = require("scripts.lifecycle")
local gui = require("scripts.gui")
local builder = require("scripts.builder")

local D = defines.direction
local RATE = H.RATE
local ITEM = "iron-plate"

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

---@param block LuaEntity
---@return mb.Balancer rec, integer id
local function rec_of(block)
  local id = assert(groups.of(block.unit_number), "block without a group")
  local rec = assert(balancer.get(id), "no balancer for group " .. tostring(id))
  return rec, id
end

local function near(v, want, what)
  assert(math.abs(v - want) <= want * 0.01, string.format("%s: %.3f, expected %.3f within 1 %%", what, v, want))
end

-- Hidden entities of type `t` in a placed network.
---@param rec mb.Balancer
---@param t string
---@return integer
local function count_type(rec, t)
  local n = 0
  for _, e in ipairs(assert(rec.placed).entities) do
    if e.valid and e.type == t then
      n = n + 1
    end
  end
  return n
end

local function fmt(list)
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = string.format("%.2f", v)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- An input into the west side of the block at (bx, by) that carries items on its left lane only:
-- 4 belts pointing east, and a feeder column (chest, loader, belt) side-loading the second belt
-- from the north.
local function left_feed(o, bx, by, stock)
  for k = 1, 4 do
    H.put(o, bx - k, by, H.BELT, D.east)
  end
  local x = bx - 3
  H.put(o, x, by - 1, H.BELT, D.south)
  H.put(o, x, by - 2, "mb-test-loader-" .. H.TIER, D.south, { type = "output" })
  local chest = H.put(o, x, by - 3, "mb-test-chest")
  chest.insert({ name = ITEM, count = stock })
end

-- Every tick, counts and clears the items on each lane of each belt in `belts`.
-- Returns counts[j] = { left, right }.
local function lane_counter(belts)
  local counts = {}
  for j = 1, #belts do
    counts[j] = { 0, 0 }
  end
  on_tick(function()
    for j, b in ipairs(belts) do
      for li = 1, 2 do
        local line = b.get_transport_line(H.LINES[li])
        local n = line.get_item_count()
        if n > 0 then
          counts[j][li] = counts[j][li] + n
          line.clear()
        end
      end
    end
  end)
  return counts
end

-- A fake LuaLazyLoadedValue for on_player_setup_blueprint's mapping.
local function lazy(v)
  return { valid = true, get = function() return v end }
end

-- A blueprint in a script inventory of `bbox`, set up through the mod's handler as a player's
-- selection would be. Returns the stack and the inventory (destroy it when done).
local function blueprint_of(bbox)
  local inv = game.create_inventory(1)
  inv.insert({ name = "blueprint" })
  local bp = inv[1]
  local map = bp.create_blueprint({ surface = game.surfaces.nauvis, force = "player", area = bbox })
  lifecycle.on_player_setup_blueprint({ player_index = nil, stack = bp, mapping = lazy(map) })
  return bp, inv
end

-- Pastes `bp` at `position` and revives its ghosts (raise_revive, as robots would).
local function paste(bp, position, box)
  local s = game.surfaces.nauvis
  bp.build_blueprint({ surface = s, force = "player", position = position, build_mode = defines.build_mode.forced, raise_built = true })
  for _, g in ipairs(s.find_entities_filtered({ area = box, type = "entity-ghost" })) do
    if g.valid then
      g.revive({ raise_revive = true })
    end
  end
end

---@return LuaEntity[]
local function blocks_in(box)
  local list = {}
  for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = box, type = "simple-entity-with-owner" })) do
    if groups.tier_of(e.name) then
      list[#list + 1] = e
    end
  end
  return list
end

local function same(s, lanes, recirc, what)
  assert(s.lanes == lanes and s.recirc == recirc,
    string.format("%s: lanes %s, recirc %s; expected %s, %s", what, tostring(s.lanes), tostring(s.recirc), tostring(lanes), tostring(recirc)))
end

describe("lanes", function()
  after_each(function()
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- Review Focus 3. A running 2:3 fed on its left input lanes only. Turning lane balancing on
  -- rebuilds it with every item kept; then both lanes of every output carry the same (7.5/s each:
  -- two half belts in, spread over six lanes).
  test("toggle_lanes_on_full_balancer", function()
    async(900 + 600 + 600 + 3600 + 300)
    local o, box = area(14, 12)
    local blocks = {}
    for y = 0, 4 do
      blocks[#blocks + 1] = H.block(o, 6, y + 2, H.TIER)
    end
    local STOCK = 4000
    left_feed(o, 6, 2, STOCK)
    left_feed(o, 6, 6, STOCK)
    local sinks = {}
    for _, y in ipairs({ 2, 4, 6 }) do
      sinks[#sinks + 1] = H.sink(o, 6, y, D.east, 3)
    end
    balancer.flush()
    local rec, gid = rec_of(blocks[1])
    assert(rec.n == 2 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:3")
    assert(rec.lanes ~= true and count_type(rec, "lane-splitter") == 0, "test setup: lanes balanced already")
    after_ticks(900, function()
      local total = H.count_box(box, ITEM)
      assert(total == 2 * STOCK, "before the toggle: " .. total .. " of " .. 2 * STOCK)
      assert(H.network_of(gid) > 0, "test setup: the network holds nothing")
      -- baseline (review M9): without lane balancing the outputs carry the left lane only
      local left, right = 0, 0
      for _, r in ipairs(sinks) do
        for _, belt in ipairs(r.belts) do
          if belt.valid then -- the first tile is an edge now
            left = left + belt.get_transport_line(H.LINES[1]).get_item_count()
            right = right + belt.get_transport_line(H.LINES[2]).get_item_count()
          end
        end
      end
      assert(left > 0 and right == 0, "test setup: output lanes before the toggle " .. left .. " / " .. right)
      assert(gui.set(gid, { lanes = true }), "the setting did not change")
      same(groups.settings(gid), true, true, "after the toggle")
      balancer.flush()
      local r2 = rec_of(blocks[1])
      assert(r2.lanes == true, "the network was not rebuilt with lanes")
      assert(count_type(r2, "lane-splitter") == 2, count_type(r2, "lane-splitter") .. " lane splitters, expected 2")
      local after = H.count_box(box, ITEM)
      H.report("toggle_lanes: %d items before, %d after the rebuild", total, after)
      assert(after == total, "after the rebuild: " .. after .. " of " .. total)
      after_ticks(600, function()
        assert(H.count_box(box, ITEM) == total, "600 ticks after: " .. H.count_box(box, ITEM) .. " of " .. total)
        local last = {}
        for j, r in ipairs(sinks) do
          last[j] = r.belts[3]
        end
        local counts = lane_counter(last)
        H.measure(function()
          local c = {}
          for j = 1, #counts do
            c[#c + 1] = counts[j][1]
            c[#c + 1] = counts[j][2]
          end
          return c
        end, 600, 3600, function(rates)
          H.report("toggle_lanes: lanes (left right per output) %s items/s, total %.3f", fmt(rates), H.sum(rates))
          H.assert_equal(rates, "lane")
          near(H.sum(rates), RATE, "total")
          done()
        end)
      end)
    end)
  end)

  -- A running 2:3 with full inputs. Turning recirculation off rebuilds the plain network (smaller)
  -- with every item kept, and with all outputs free it is still exact; turning it on again keeps
  -- every item too.
  test("toggle_recirc_on_full_balancer", function()
    async(900 + 600 + 3600 + 600 + 300)
    local o, box = area(12, 8)
    local blocks = {}
    for y = 0, 2 do
      blocks[#blocks + 1] = H.block(o, 5, y + 2, H.TIER)
    end
    local STOCK = 6000
    H.feed(o, 5, 2, D.west, 3, { stock = STOCK })
    H.feed(o, 5, 4, D.west, 3, { stock = STOCK })
    local sinks = {}
    for y = 2, 4 do
      sinks[#sinks + 1] = H.sink(o, 5, y, D.east, 3)
    end
    balancer.flush()
    local rec, gid = rec_of(blocks[1])
    assert(rec.n == 2 and rec.m == 3, "network " .. rec.n .. ":" .. rec.m .. ", expected 2:3")
    local big = #assert(rec.placed).entities
    after_ticks(900, function()
      local total = H.count_box(box, ITEM)
      assert(total == 2 * STOCK, "before the toggle: " .. total .. " of " .. 2 * STOCK)
      assert(gui.set(gid, { recirc = false }), "the setting did not change")
      same(groups.settings(gid), false, false, "after the toggle")
      balancer.flush()
      local r2 = rec_of(blocks[1])
      assert(r2.recirc == false, "the network was not rebuilt without recirculation")
      local small = #assert(r2.placed).entities
      assert(small < big, "plain network " .. small .. " entities, recirculating " .. big)
      local after = H.count_box(box, ITEM)
      H.report("toggle_recirc: %d entities with recirculation, %d without; %d items before, %d after", big, small, total, after)
      assert(after == total, "after the rebuild: " .. after .. " of " .. total)
      H.measure(function()
        local c = {}
        for j, r in ipairs(sinks) do
          c[j] = r.chest.get_item_count()
        end
        return c
      end, 600, 3600, function(rates)
        H.report("toggle_recirc: plain outputs %s items/s", fmt(rates))
        for j, v in ipairs(rates) do
          near(v, 2 * RATE / 3, "output " .. j)
        end
        local before = H.count_box(box, ITEM)
        assert(gui.set(gid, { recirc = true }), "the setting did not change back")
        balancer.flush()
        local r3 = rec_of(blocks[1])
        assert(r3.recirc == true and #assert(r3.placed).entities > small, "not rebuilt with recirculation")
        assert(H.count_box(box, ITEM) == before, "after turning it on again: " .. H.count_box(box, ITEM) .. " of " .. before)
        after_ticks(600, function()
          assert(H.count_box(box, ITEM) == before, "600 ticks later: " .. H.count_box(box, ITEM) .. " of " .. before)
          done()
        end)
      end)
    end)
  end)

  -- Review Focus 4. Settings paste between blocks copies both settings to the destination's
  -- balancer (and rebuilds it); a blueprint of a balancer with lanes on and recirculation off
  -- carries both as block tags, and the pasted balancer has them.
  test("settings_paste_and_blueprint_keep_lanes", function()
    async(200)
    local o, box = area(16, 8)
    local a1 = H.block(o, 3, 3, H.TIER)
    H.block(o, 3, 4, H.TIER)
    H.feed(o, 3, 3, D.west, 2, { stock = 200 })
    H.sink(o, 3, 3, D.east, 2)
    H.sink(o, 3, 4, D.east, 2)
    local b = H.block(o, 11, 3, H.TIER)
    H.feed(o, 11, 3, D.west, 2, { stock = 200 })
    H.sink(o, 11, 3, D.east, 2)
    H.sink(o, 11, 3, D.south, 2)
    balancer.flush()
    local ra, ga = rec_of(a1)
    local rb, gb = rec_of(b)
    assert(ga ~= gb and ra.placed and rb.placed, "test setup: two running balancers expected")
    same(groups.settings(gb), false, true, "defaults")
    gui.set(ga, { lanes = true, recirc = false })
    balancer.flush()
    local ra2 = rec_of(a1)
    assert(ra2.lanes == true and ra2.recirc == false, "source not rebuilt with its settings")

    -- settings paste (shift right-click, shift left-click)
    events.on_settings_pasted({ source = a1, destination = b, player_index = nil })
    same(groups.settings(gb), true, false, "after the paste")
    balancer.flush()
    local rb2 = rec_of(b)
    assert(rb2.lanes == true and rb2.recirc == false and count_type(rb2, "lane-splitter") == 1, "destination not rebuilt with the pasted settings")
    same(groups.settings(ga), true, false, "the source after the paste")

    -- blueprint of the two-block balancer
    local bp, inv = blueprint_of({ { o.x - 0.5, o.y + 1.5 }, { o.x + 6.5, o.y + 5.5 } })
    local tagged = 0
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      if groups.tier_of(be.name) then
        local t = be.tags or {}
        assert(t.mb_lanes == true and t.mb_recirc == false, "block tags " .. serpent.line(be.tags))
        tagged = tagged + 1
      end
      assert(be.name:sub(1, 8) ~= "mb-edge-", "the blueprint holds an edge")
    end
    assert(tagged == 2, tagged .. " blocks tagged, expected 2")
    -- a blueprint of a default balancer carries the defaults
    gui.set(gb, { lanes = false, recirc = true })
    local bp2, inv2 = blueprint_of({ { o.x + 8.5, o.y + 1.5 }, { o.x + 14.5, o.y + 6.5 } })

    local o2, box2 = area(8, 8)
    paste(bp, { o2.x + 3, o2.y + 4 }, box2)
    local pasted = blocks_in(box2)
    assert(#pasted == 2, #pasted .. " blocks pasted, expected 2")
    local gp = groups.of(pasted[1].unit_number)
    assert(gp and gp == groups.of(pasted[2].unit_number), "the pasted blocks are not one group")
    same(groups.settings(gp), true, false, "pasted balancer")
    balancer.flush()
    local rp = rec_of(pasted[1])
    assert(rp.placed and rp.lanes == true and rp.recirc == false, "pasted balancer not built with its settings")

    local o3, box3 = area(8, 8)
    paste(bp2, { o3.x + 3, o3.y + 4 }, box3)
    local p3 = assert(blocks_in(box3)[1], "default blueprint: no block")
    same(groups.settings(groups.of(p3.unit_number)), false, true, "pasted default balancer")
    inv.destroy()
    inv2.destroy()
    -- nothing was lost in the source area (both balancers kept their items through the rebuilds)
    after_ticks(120, function()
      assert(H.count_box(box, ITEM) == 400, "source area: " .. H.count_box(box, ITEM) .. " of 400")
      done()
    end)
  end)

  -- A merge keeps the larger group's settings, in both directions, and a split gives every part
  -- the old group's settings.
  test("merge_takes_larger_groups_setting", function()
    local o, box = area(14, 10)
    -- larger group (3 blocks) with lanes on and recirculation off, smaller (1 block) with defaults
    local big = H.block(o, 2, 2, H.TIER)
    H.block(o, 3, 2, H.TIER)
    H.block(o, 4, 2, H.TIER)
    local small = H.block(o, 6, 2, H.TIER)
    H.feed(o, 2, 2, D.west, 2, { stock = 100 })
    H.sink(o, 6, 2, D.east, 2)
    H.sink(o, 3, 2, D.south, 2)
    balancer.flush()
    local gbig = groups.of(big.unit_number)
    gui.set(gbig, { lanes = true, recirc = false })
    balancer.flush()
    same(groups.settings(groups.of(small.unit_number)), false, true, "small group")
    local mid = H.block(o, 5, 2, H.TIER)
    balancer.flush()
    local g = groups.of(small.unit_number)
    assert(g == groups.of(big.unit_number), "the blocks did not merge")
    same(groups.settings(g), true, false, "merged (larger had lanes on, recirculation off)")
    local rec = rec_of(big)
    assert(rec.placed and rec.lanes == true and rec.recirc == false, "merged network not built with the larger group's settings")

    -- split: both parts keep the settings
    mid.destroy({ raise_destroy = true })
    balancer.flush()
    local g1, g2 = groups.of(big.unit_number), groups.of(small.unit_number)
    assert(g1 ~= g2, "the row did not split")
    same(groups.settings(g1), true, false, "split part 1")
    same(groups.settings(g2), true, false, "split part 2")

    -- the other direction: the larger group has the defaults, the smaller lanes on and
    -- recirculation off
    gui.set(g1, { lanes = false, recirc = true })
    local lone = H.block(o, 2, 7, H.TIER)
    H.block(o, 3, 7, H.TIER)
    H.block(o, 4, 7, H.TIER)
    local one = H.block(o, 6, 7, H.TIER)
    local gl, go = groups.of(lone.unit_number), groups.of(one.unit_number)
    gui.set(go, { lanes = true, recirc = false })
    same(groups.settings(gl), false, true, "larger group (defaults)")
    H.block(o, 5, 7, H.TIER)
    local gm = groups.of(one.unit_number)
    assert(gm == groups.of(lone.unit_number), "the second row did not merge")
    same(groups.settings(gm), false, true, "merged (larger had the defaults)")
    balancer.flush()
    local total = H.count_box(box, ITEM)
    assert(total == 100, "items: " .. total .. " of 100")
  end)

  -- Task 3 review M1, M2, M4, M5 (Plan 3 Task 5). The handlers of the open, copy and paste
  -- controls and of the checkboxes, driven with stand-in players (a headless test has no
  -- LuaPlayer; the real player is checked on an MCP instance, docs/feasibility.md F11).
  test("gui_handlers_follow_reach_permissions_and_current_settings", function()
    local o, box = area(14, 8)
    local a = H.block(o, 2, 2, H.TIER)
    H.block(o, 3, 2, H.TIER)
    local b = H.block(o, 8, 2, H.TIER)
    local c = H.block(o, 11, 2, H.TIER)
    local other = game.forces["mb-test-other"] or game.create_force("mb-test-other")
    local foreign = H.block(o, 2, 6, H.TIER, other)
    local ga, gb, gc = groups.of(a.unit_number), groups.of(b.unit_number), groups.of(c.unit_number)
    assert(ga and gb and gc and ga ~= gb and gb ~= gc, "test setup: three groups expected")
    local C = defines.controllers
    local reach = true
    local function player(t)
      local p = {
        valid = true, index = 77, name = "stand-in", force = game.forces.player, controller_type = C.character,
        gui = { screen = {} },
        can_reach_entity = function()
          return reach
        end,
        is_cursor_empty = function()
          return true
        end,
      }
      for k, v in pairs(t or {}) do
        p[k] = v
      end
      return p
    end
    local deny_all = { allows_action = function() return false end }
    local opened = {}
    local real_open = gui.open
    gui.open = function(_, e)
      opened[#opened + 1] = e
    end
    local ok, err = pcall(function()
      -- open (M2, M5)
      local function opens(p, what)
        local n = #opened
        ---@diagnostic disable-next-line: param-type-mismatch
        local r = gui.open_input(p)
        assert(r == (#opened > n), what .. ": return value and open disagree")
        return r
      end
      assert(opens(player({ selected = a }), "in reach"), "a block in reach did not open")
      reach = false
      assert(not opens(player({ selected = a }), "out of reach"), "a block out of reach opened")
      assert(opens(player({ selected = a, controller_type = C.remote }), "remote view"), "remote view did not open")
      reach = true
      assert(not opens(player({ selected = foreign }), "other force"), "another force's block opened")
      assert(not opens(player({ selected = a, is_cursor_empty = function() return false end }), "cursor"), "opened with a full cursor")
      assert(not opens(player({ selected = a, permission_group = deny_all }), "permissions"), "opened without the open-gui permission")
      assert(not opens(player({ selected = nil }), "nothing"), "opened with nothing selected")

      -- copy then paste reads the source's current settings (M4)
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.copy_input(player({ selected = a }))
      gui.set(ga, { lanes = true, recirc = false })
      reach = false
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.paste_input(player({ selected = b })), "pasted out of reach")
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.paste_input(player({ selected = b, controller_type = C.remote, permission_group = deny_all })), "pasted without the permission")
      same(groups.settings(gb), false, true, "after the refused pastes")
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(gui.paste_input(player({ selected = b, controller_type = C.remote })), "remote view paste did nothing")
      reach = true
      same(groups.settings(gb), true, false, "after the paste (the source's settings when pasted)")
      -- a copied block that is gone pastes nothing (as vanilla)
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.copy_input(player({ selected = c }))
      gui.set(gb, { lanes = false, recirc = true })
      c.destroy({ raise_destroy = true })
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.paste_input(player({ selected = b })), "a gone source pasted")
      same(groups.settings(gb), false, true, "after pasting a gone source")
      -- copying something else forgets the block
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.copy_input(player({ selected = a }))
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.copy_input(player({ selected = nil }))
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.paste_input(player({ selected = b })), "pasted after copying nothing")

      -- checkboxes: on the open block's group; a gone block closes (M3)
      storage.mb_gui.open[77] = b
      local el = { valid = true, tags = { mb_setting = "lanes" }, state = true } --[[@as any]]
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(gui.checked(player(), el), "the checkbox changed nothing")
      same(groups.settings(gb), true, true, "after the checkbox")
      local foreign_el = { valid = true, tags = { mb_setting = "other" }, state = true } --[[@as any]]
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.checked(player(), foreign_el), "a foreign element changed a setting")
      reach = false
      local recirc_el = { valid = true, tags = { mb_setting = "recirc" }, state = false } --[[@as any]]
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(not gui.checked(player(), recirc_el), "changed out of reach")
      assert(storage.mb_gui.open[77] == nil, "out of reach: the frame was not closed")
      reach = true

      -- a removed player leaves nothing behind (M1)
      storage.mb_gui.open[77] = b
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.copy_input(player({ selected = a }))
      gui.forget(77)
      assert(storage.mb_gui.open[77] == nil and storage.mb_gui.copy[77] == nil, "state kept for a removed player")
    end)
    gui.open = real_open
    storage.mb_gui.open[77], storage.mb_gui.copy[77] = nil, nil
    foreign.destroy({ raise_destroy = true })
    assert(ok, err)
    -- the frame's styles exist (gui.open on a real player uses them)
    for _, style in ipairs({ "frame_title", "draggable_space_header", "frame_action_button", "inside_shallow_frame_with_padding" }) do
      ---@diagnostic disable-next-line: unnecessary-assert
      assert(prototypes.style[style], "no style " .. style)
    end
    balancer.flush()
    assert(H.count_box(box, ITEM) == 0, "items appeared")
  end)

  -- M9: a block built from a blueprint with settings tags that joins an existing group takes the
  -- group's settings (the tags only start a new group).
  test("tagged_block_joining_a_group_ignores_its_tags", function()
    local o, box = area(8, 6)
    local a = H.block(o, 2, 2, H.TIER)
    local inv = game.create_inventory(1)
    inv.insert({ name = "blueprint" })
    local bp = inv[1]
    bp.set_blueprint_entities({
      { entity_number = 1, name = "mb-balancer-" .. H.TIER, position = { 0.5, 0.5 }, tags = { mb_lanes = true, mb_recirc = false } },
    })
    paste(bp, { o.x + 3, o.y + 2 }, box)
    local joined = H.at(o, 3, 2, "simple-entity-with-owner")
    assert(joined and groups.of(joined.unit_number) == groups.of(a.unit_number), "the pasted block did not join")
    same(groups.settings(groups.of(a.unit_number)), false, true, "joined group")
    -- alone, the same blueprint starts a group with its settings
    paste(bp, { o.x + 6, o.y + 4 }, box)
    local lone = assert(H.at(o, 6, 4, "simple-entity-with-owner"), "the second paste built nothing")
    same(groups.settings(groups.of(lone.unit_number)), true, false, "new group from tags")
    inv.destroy()
  end)

  -- M9: a clone that starts a new group takes its source group's settings; a teleported block
  -- that leaves its group keeps them, one that joins another group takes that group's.
  test("clone_and_teleport_keep_settings", function()
    local o = area(14, 8)
    local a = H.block(o, 2, 2, H.TIER)
    H.block(o, 3, 2, H.TIER)
    local ga = groups.of(a.unit_number)
    gui.set(ga, { lanes = true, recirc = false })
    local clone = assert(a.clone({ position = { o.x + 8, o.y + 2 } }), "clone failed")
    same(groups.settings(groups.of(clone.unit_number)), true, false, "clone")
    local b = H.block(o, 2, 6, H.TIER)
    same(groups.settings(groups.of(b.unit_number)), false, true, "plain block")
    assert(a.teleport({ o.x + 11, o.y + 6 }, nil, true), "teleport refused")
    same(groups.settings(groups.of(a.unit_number)), true, false, "teleported out alone")
    assert(a.teleport({ o.x + 3, o.y + 6 }, nil, true), "teleport refused")
    assert(groups.of(a.unit_number) == groups.of(b.unit_number), "the teleported block did not join")
    same(groups.settings(groups.of(b.unit_number)), false, true, "teleported into a plain group")
  end)

  -- M9: after game.merge_forces, touching groups merge and keep the larger group's settings.
  test("forces_merged_keeps_the_larger_groups_settings", function()
    async(120)
    local o = area(8, 6)
    local fa = game.forces["mb-test-lanes-a"] or game.create_force("mb-test-lanes-a")
    local big = H.block(o, 2, 2, H.TIER, fa)
    H.block(o, 3, 2, H.TIER, fa)
    local small = H.block(o, 4, 2, H.TIER)
    gui.set(groups.of(big.unit_number), { lanes = true, recirc = false })
    assert(groups.of(big.unit_number) ~= groups.of(small.unit_number), "test setup: forces joined")
    game.merge_forces(fa, game.forces.player)
    after_ticks(2, function()
      local g = groups.of(small.unit_number)
      assert(g and g == groups.of(big.unit_number), "the groups did not merge")
      same(groups.settings(g), true, false, "merged after the force merge")
      done()
    end)
  end)

  -- M9: a toggle and a merge in one batch: one flush rebuilds with the new settings and the
  -- merged network's items.
  test("toggle_and_merge_in_one_flush", function()
    async(900)
    local o, box = area(14, 8)
    local a = H.block(o, 3, 3, H.TIER)
    H.feed(o, 3, 3, D.west, 3, { stock = 300 })
    H.sink(o, 3, 3, D.north, 2)
    local b = H.block(o, 5, 3, H.TIER)
    H.feed(o, 5, 3, D.south, 2, { stock = 300 })
    H.sink(o, 5, 3, D.east, 3)
    balancer.flush()
    assert(groups.of(a.unit_number) ~= groups.of(b.unit_number), "test setup: one group")
    after_ticks(600, function()
      local total = H.count_box(box, ITEM)
      assert(total == 600, "before: " .. total .. " of 600")
      gui.set(groups.of(a.unit_number), { lanes = true })
      H.block(o, 4, 3, H.TIER) -- joins both; a and b are the same size, so the lower id wins
      local g = groups.of(a.unit_number)
      assert(g == groups.of(b.unit_number), "the blocks did not merge")
      local want = groups.settings(g)
      balancer.flush()
      local rec = rec_of(a)
      assert(rec.placed and rec.lanes == want.lanes and rec.recirc == want.recirc, "not rebuilt with the merged settings")
      assert(#rec.extra == 0, "a merged network was not carried in")
      assert(H.count_box(box, ITEM) == total, "after the flush: " .. H.count_box(box, ITEM) .. " of " .. total)
      after_ticks(120, function()
        assert(H.count_box(box, ITEM) == total, "later: " .. H.count_box(box, ITEM) .. " of " .. total)
        done()
      end)
    end)
  end)

  -- Task 3 review M6: a rebuild for a setting that is refused (too many items) keeps the old
  -- network, and the group's settings go back to that network's, so the GUI shows what the
  -- balancer does. The refusal is forced by a stand-in builder.start.
  test("refused_rebuild_sets_the_settings_back", function()
    async(700)
    local o, box = area(12, 8)
    local a = H.block(o, 4, 3, H.TIER)
    H.feed(o, 4, 3, D.west, 3, { stock = 300 })
    H.sink(o, 4, 3, D.east, 3)
    H.sink(o, 4, 3, D.south, 2)
    balancer.flush()
    after_ticks(600, function()
      local rec, gid = rec_of(a)
      local placed = rec.placed
      local total = H.count_box(box, ITEM)
      assert(gui.set(gid, { recirc = false }), "the setting did not change")
      -- the staged rebuild starts its placement with builder.start (scripts/balancer.lua)
      local real = builder.start
      builder.start = function()
        return nil, "too-many-items"
      end
      local ok, err = pcall(balancer.flush)
      builder.start = real
      assert(ok, err)
      local r2 = rec_of(a)
      assert(r2.placed == placed and r2.recirc ~= false, "the old network was not kept")
      local reasons = {}
      for _, r in ipairs(r2.refused) do
        reasons[#reasons + 1] = r.reason
      end
      assert(table.concat(reasons, ","):find("too-many-items", 1, true), "no refusal: " .. serpent.line(reasons))
      same(groups.settings(gid), false, true, "settings after the refused rebuild")
      assert(H.count_box(box, ITEM) == total, "items: " .. H.count_box(box, ITEM) .. " of " .. total)
      -- the next change rebuilds normally
      assert(gui.set(gid, { recirc = false }), "the setting did not change again")
      balancer.flush()
      assert(rec_of(a).recirc == false, "not rebuilt after the refusal")
      assert(H.count_box(box, ITEM) == total, "items after the rebuild: " .. H.count_box(box, ITEM) .. " of " .. total)
      done()
    end)
  end)
end)
