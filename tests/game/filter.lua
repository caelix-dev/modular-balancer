-- Per-block item filters (scripts/filters.lua, filtered networks in scripts/network.lua): items go
-- only where the filters let them, a filter travels with paste, blueprints, ghosts, clones and
-- upgrades, and the frame's filter part works. fdev test is headless, so the GUI handlers are
-- driven with a stand-in player and stand-in elements (as in tests/game/lanes.lua). Express belts.
-- Plain assert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local groups = require("scripts.groups")
local lifecycle = require("scripts.lifecycle")
local gui = require("scripts.gui")

local D = defines.direction

local boxes = {}
local function area(w, h)
  local o, box = H.area(w, h)
  boxes[#boxes + 1] = box
  return o, box
end

local function chest_count(r, item)
  return r.chest.get_item_count(item)
end

-- Items of each name on each lane of `belts`: t[lane][name].
local function lanes_of(belts)
  ---@type { [1]: table<string, integer>, [2]: table<string, integer> }
  local t = { {}, {} }
  for _, b in ipairs(belts) do
    if b.valid then -- the first belt became an edge
      for li = 1, 2 do
        for _, c in ipairs(b.get_transport_line(H.LINES[li]).get_contents()) do
          local lane = t[li] --[[@as table<string, integer>]]
          lane[c.name] = (lane[c.name] or 0) + c.count
        end
      end
    end
  end
  return t
end

-- A fake LuaLazyLoadedValue for on_player_setup_blueprint's mapping.
local function lazy(v)
  return { valid = true, get = function() return v end }
end

local function filter_is(e, want, what)
  local f = gui.filter_of(e)
  local got = f and serpent.line(f) or "nil"
  local exp = want and serpent.line(want) or "nil"
  assert(got == exp, what .. ": filter " .. got .. ", expected " .. exp)
end

-- A stand-in GUI element.
---@return any
local function fake(t)
  return t
end

local C = defines.controllers
local function stand_in(t)
  local p = {
    valid = true, index = 77, name = "stand-in", force = game.forces.player, controller_type = C.character,
    gui = { screen = {} },
    can_reach_entity = function()
      return true
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

describe("filter", function()
  after_each(function()
    for _, box in ipairs(boxes) do
      H.clear_blocks(box)
    end
    boxes = {}
  end)

  -- A 2:3 of two blocks, iron into the top block and copper into the bottom one; the top block
  -- whitelists iron. Every iron plate leaves through the top block's output, every copper plate
  -- through the bottom block's two outputs, shared equally. Nothing is lost.
  test("whitelist_is_exclusive_and_shared", function()
    async(1200)
    local o, box = area(14, 12)
    local a = H.block(o, 6, 3, H.TIER)
    local b = H.block(o, 6, 4, H.TIER)
    local STOCK = 3000
    H.feed(o, 6, 3, D.west, 3, { stock = STOCK, item = "iron-plate" })
    H.feed(o, 6, 4, D.west, 3, { stock = STOCK, item = "copper-plate" })
    local sa = H.sink(o, 6, 3, D.east, 3)
    local sb1 = H.sink(o, 6, 4, D.east, 3)
    local sb2 = H.sink(o, 6, 4, D.south, 3)
    balancer.flush()
    assert(gui.set_filter(a, { items = { "iron-plate" } }), "the filter changed nothing")
    balancer.flush()
    local rec = assert(balancer.get(groups.of(b.unit_number)))
    assert(rec.n == 2 and rec.m == 3 and rec.fsig and rec.fsig:find("W:iron%-plate"), "network " .. rec.n .. ":" .. rec.m .. " " .. tostring(rec.fsig))
    after_ticks(1000, function()
      local ia, ca = chest_count(sa, "iron-plate"), chest_count(sa, "copper-plate")
      local i1, c1 = chest_count(sb1, "iron-plate"), chest_count(sb1, "copper-plate")
      local i2, c2 = chest_count(sb2, "iron-plate"), chest_count(sb2, "copper-plate")
      H.report("filter whitelist: A iron %d copper %d, B1 iron %d copper %d, B2 iron %d copper %d", ia, ca, i1, c1, i2, c2)
      assert(ia > 300 and ca == 0, "the iron block got iron " .. ia .. ", copper " .. ca)
      assert(i1 == 0 and i2 == 0, "iron reached the other block: " .. i1 .. ", " .. i2)
      assert(c1 > 150 and c2 > 150 and math.abs(c1 - c2) <= 0.05 * (c1 + c2) + 8, "copper not shared equally: " .. c1 .. ", " .. c2)
      assert(H.count_box(box, "iron-plate") == STOCK and H.count_box(box, "copper-plate") == STOCK, "items lost or made")
      done()
    end)
  end)

  -- Three inputs (iron, copper, stone) and two outputs: the top block excludes iron, the middle one
  -- filters per lane (iron left, copper right). The top block gets only stone (copper is claimed by
  -- the lane filter), the middle one iron on its left lane and copper on its right lane only.
  test("exclude_and_per_lane", function()
    async(1200)
    local o, box = area(14, 12)
    local a = H.block(o, 6, 3, H.TIER)
    local b = H.block(o, 6, 4, H.TIER)
    H.block(o, 6, 5, H.TIER)
    local STOCK = 2000
    H.feed(o, 6, 3, D.west, 3, { stock = STOCK, item = "iron-plate" })
    H.feed(o, 6, 4, D.west, 3, { stock = STOCK, item = "copper-plate" })
    H.feed(o, 6, 5, D.west, 3, { stock = STOCK, item = "stone" })
    local sa = H.sink(o, 6, 3, D.east, 3)
    local sb = H.sink(o, 6, 4, D.east, 3)
    gui.set_filter(a, { items = { "iron-plate" }, exclude = true })
    gui.set_filter(b, { items = { "iron-plate", "copper-plate", "stone" }, lanes = true, exclude = true })
    balancer.flush()
    local rec = assert(balancer.get(groups.of(b.unit_number)))
    assert(rec.n == 3 and rec.m == 2, "network " .. rec.n .. ":" .. rec.m)
    after_ticks(1000, function()
      local t = lanes_of(sb.belts)
      H.report("filter lanes: belt left %s right %s; A chest stone %d iron %d copper %d; B chest iron %d copper %d stone %d",
        serpent.line(t[1]), serpent.line(t[2]), chest_count(sa, "stone"), chest_count(sa, "iron-plate"), chest_count(sa, "copper-plate"),
        chest_count(sb, "iron-plate"), chest_count(sb, "copper-plate"), chest_count(sb, "stone"))
      assert((t[1]["iron-plate"] or 0) > 0 and t[1]["copper-plate"] == nil and t[1].stone == nil, "left lane: " .. serpent.line(t[1]))
      assert((t[2]["copper-plate"] or 0) > 0 and t[2]["iron-plate"] == nil and t[2].stone == nil, "right lane: " .. serpent.line(t[2]))
      assert(chest_count(sb, "stone") == 0, "stone reached the lane block")
      assert(chest_count(sb, "iron-plate") > 100 and chest_count(sb, "copper-plate") > 100, "the lane block is starved")
      assert(chest_count(sa, "stone") > 300 and chest_count(sa, "iron-plate") == 0 and chest_count(sa, "copper-plate") == 0,
        "the excluding block got something else than stone")
      for _, item in ipairs({ "iron-plate", "copper-plate", "stone" }) do
        assert(H.count_box(box, item) == STOCK, item .. " lost or made: " .. H.count_box(box, item))
      end
      done()
    end)
  end)

  -- Removing a filter from a running balancer rebuilds it to the plain network with every item.
  test("filter_off_rebuilds_with_items", function()
    async(900)
    local o, box = area(14, 12)
    local a = H.block(o, 6, 3, H.TIER)
    H.block(o, 6, 4, H.TIER)
    H.feed(o, 6, 3, D.west, 3, { stock = 2000, item = "iron-plate" })
    local sa = H.sink(o, 6, 3, D.east, 3)
    local sb = H.sink(o, 6, 4, D.east, 3)
    gui.set_filter(a, { items = { "copper-plate" } }) -- the iron has only the lower output
    balancer.flush()
    after_ticks(400, function()
      assert(chest_count(sa, "iron-plate") == 0 and chest_count(sb, "iron-plate") > 100, "the filter does not route")
      assert(gui.set_filter(a, nil), "clearing changed nothing")
      balancer.flush()
      local rec = assert(balancer.get(groups.of(a.unit_number)))
      assert(rec.fsig == nil, "still filtered: " .. tostring(rec.fsig))
      local before = chest_count(sa, "iron-plate")
      after_ticks(400, function()
        assert(chest_count(sa, "iron-plate") > before + 100, "the unfiltered output gets nothing")
        assert(H.count_box(box, "iron-plate") == 2000, "items lost or made")
        done()
      end)
    end)
  end)

  -- A filter is the block's own: paste within a group copies it, blueprints, ghosts, clones,
  -- upgrades and fast-replace builds keep it; the GUI handlers set slots and flags, and the
  -- frame locks slots 3 to 5 and Exclude per lane.
  test("filter_travels", function()
    local o, box = area(20, 12)
    local s = game.surfaces.nauvis
    local a = H.block(o, 2, 2, H.TIER)
    local b = H.block(o, 3, 2, H.TIER)
    local fa = { items = { "iron-plate", "", "", "", "" }, exclude = false, lanes = false }
    gui.set_filter(a, fa)
    filter_is(b, nil, "the neighbour")
    -- paste within one group: the filter only
    assert(gui.paste(a, b), "paste within a group did nothing")
    filter_is(b, fa, "pasted within the group")

    -- blueprint
    local inv = game.create_inventory(1)
    inv.insert({ name = "blueprint" })
    local bp = inv[1]
    local map = bp.create_blueprint({ surface = s, force = "player", area = { { o.x + 1.5, o.y + 1.5 }, { o.x + 3.5, o.y + 2.5 } } })
    lifecycle.on_player_setup_blueprint({ player_index = nil, stack = bp, mapping = lazy(map) })
    local tagged = 0
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      if be.tags and be.tags.mb_filter then
        tagged = tagged + 1
      end
    end
    assert(tagged == 2, "blueprint blocks tagged with a filter: " .. tagged)
    bp.build_blueprint({ surface = s, force = "player", position = { o.x + 2.5, o.y + 6.5 }, build_mode = defines.build_mode.forced, raise_built = true })
    local ghosts = s.find_entities_filtered({ area = box, type = "entity-ghost" })
    assert(#ghosts == 2, "ghosts: " .. #ghosts)
    for _, g in ipairs(ghosts) do
      filter_is(g, fa, "a blueprint ghost")
      local _, e = g.revive({ raise_revive = true })
      assert(e and e.valid, "not revived")
      filter_is(e, fa, "a block built from the blueprint")
    end
    inv.destroy()

    -- a ghost set by hand, then built
    local g = assert(s.create_entity({ name = "entity-ghost", inner_name = "mb-balancer-basic", position = { o.x + 10, o.y + 2 }, force = "player" }))
    local fl = { items = { "", "copper-plate", "", "", "" }, exclude = false, lanes = true }
    assert(gui.set_filter(g, fl), "the ghost filter changed nothing")
    filter_is(g, fl, "the ghost")
    local _, gb = g.revive({ raise_revive = true })
    assert(gb and gb.valid, "the ghost was not built")
    filter_is(gb, fl, "the built ghost")

    -- clone
    local c = a.clone({ position = { o.x + 14, o.y + 2 } })
    assert(c and c.valid, "no clone")
    filter_is(c, fa, "the clone")

    -- upgrade planner, then a fast-replace build over it
    assert(gb.order_upgrade({ target = "mb-balancer-fast", force = "player" }), "cannot mark for upgrade")
    local up = gb.apply_upgrade()
    assert(up and up.valid and up.name == "mb-balancer-fast", "not upgraded")
    filter_is(up, fl, "the upgraded block")
    local fr = s.create_entity({ name = "mb-balancer-express", position = up.position, force = "player", fast_replace = true, raise_built = true, spill = false })
    assert(fr and fr.valid, "fast replace refused")
    filter_is(fr, fl, "the fast-replaced block")

    -- GUI handlers: a slot, then per lane locks slots 3-5 and Exclude (their values kept)
    local function slot(i)
      return { valid = true, tags = { mb_slot = i }, elem_value = nil, enabled = true, tooltip = "" }
    end
    ---@type any
    local frame = {
      valid = true, destroy = function() end,
      mb_inner = {
        mb_lanes = {}, mb_recirc = {}, mb_ratio = {},
        mb_slots = { mb_slot1 = slot(1), mb_slot2 = slot(2), mb_slot3 = slot(3), mb_slot4 = slot(4), mb_slot5 = slot(5) },
        mb_fflags = { mb_exclude = { enabled = true }, mb_flanes = {} },
      },
    }
    local p = stand_in({ opened_gui_type = defines.gui_type.custom })
    p.gui.screen.mb_settings = frame
    storage.mb_gui = storage.mb_gui or { open = {}, copy = {}, where = {} }
    storage.mb_gui.open[77] = b
    local ok, err = pcall(function()
      local el = slot(3)
      el.elem_value = "stone"
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(gui.elem_changed(p, el), "a slot changed nothing")
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(gui.checked(p, fake({ valid = true, tags = { mb_setting = "exclude" }, state = true })), "exclude changed nothing")
      ---@diagnostic disable-next-line: param-type-mismatch
      assert(gui.checked(p, fake({ valid = true, tags = { mb_setting = "flanes" }, state = true })), "per lane changed nothing")
      filter_is(b, { items = { "iron-plate", "", "stone", "", "" }, exclude = true, lanes = true }, "after the GUI")
      ---@diagnostic disable-next-line: param-type-mismatch
      gui.check(p)
      local inner = frame.mb_inner
      assert(inner.mb_slots.mb_slot3.elem_value == "stone" and inner.mb_slots.mb_slot3.enabled == false, "slot 3 not shown locked")
      assert(inner.mb_slots.mb_slot1.enabled == true and inner.mb_slots.mb_slot2.enabled == true, "slots 1-2 locked")
      assert(inner.mb_fflags.mb_exclude.state == true and inner.mb_fflags.mb_exclude.enabled == false, "exclude not shown locked")
    end)
    storage.mb_gui.open[77] = nil
    assert(ok, err)
    balancer.flush()
  end)
end)
