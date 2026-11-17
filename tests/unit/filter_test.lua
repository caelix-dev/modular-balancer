---@diagnostic disable: need-check-nil, assign-type-mismatch, param-type-mismatch, unnecessary-if, impossible-if
local filters = require("scripts.filters")
local network = require("scripts.network")

-- Where item `x` entering input `i` can end up: a set of "j" (whole output j, the lane the
-- splitter chain leaves it on is not tracked) or "j:L" / "j:R" for an output whose last node is a
-- filtering lane splitter, and "dead" when it can reach an unconnected filter-splitter port.
local function reach(net, x, i)
  local out_of = {}
  for _, ed in ipairs(net.edges) do
    local key = ed.from.kind .. "#" .. ed.from.id .. "#" .. ed.from.port
    assert(not out_of[key], "source port used twice: " .. key)
    out_of[key] = ed.to
  end
  local sp = {}
  for _, s in ipairs(net.splitters) do
    sp[s.id] = s
  end
  local ls = {}
  for _, l in ipairs(net.lane_splitters or {}) do
    ls[l.id] = l
  end
  local found, seen = {}, {}
  local function walk(p, lane)
    local key = p.kind .. "#" .. p.id .. "#" .. tostring(lane)
    if seen[key] then
      return
    end
    seen[key] = true
    if p.kind == "out" then
      found[p.id .. (lane and (":" .. lane) or "")] = true
      return
    end
    local function go(port, l)
      local to = out_of[p.kind .. "#" .. p.id .. "#" .. port]
      if to then
        walk(to, l)
      elseif p.kind == "splitter" and sp[p.id].filter then
        found.dead = true
      end
    end
    if p.kind == "in" then
      go(1, lane)
    elseif p.kind == "lane_splitter" then
      local l = ls[p.id]
      if l.filter then
        local side = (l.filter == x) == (l.prio == "left") and "L" or "R"
        go(1, side)
      else
        go(1, lane)
      end
    elseif p.kind == "splitter" and sp[p.id].filter then
      go(sp[p.id].filter == x and 1 or 2, lane)
    else
      go(1, lane)
      go(2, lane)
    end
  end
  walk({ kind = "in", id = i, port = 1 }, nil)
  local list = {}
  for k in pairs(found) do
    list[#list + 1] = k
  end
  table.sort(list)
  return table.concat(list, " ")
end

local function check_ports(net)
  local into = {}
  for _, ed in ipairs(net.edges) do
    local key = ed.to.kind .. "#" .. ed.to.id .. "#" .. ed.to.port
    assert(not into[key], "target port used twice: " .. key)
    into[key] = true
  end
  for j = 1, net.n_out do
    assert(into["out#" .. j .. "#1"], "output " .. j .. " not fed")
  end
end

local function expect(net, x, want)
  for i = 1, net.n_in do
    local got = reach(net, x, i)
    assert(got == want, string.format("%s from input %d: got '%s', want '%s'", x, i, got, want))
  end
end

local W = function(...)
  return { items = { ... }, use = true }
end

return {
  normalize_drops_defaults_and_garbage = function()
    assert(filters.normalize(nil) == nil)
    assert(filters.normalize({ items = { "", "", "", "", "" } }) == nil)
    assert(filters.normalize("x") == nil)
    local f = filters.normalize({ items = { ["2"] = "iron-plate" }, exclude = true })
    assert(f and f.items[1] == "" and f.items[2] == "iron-plate" and f.exclude and not f.lanes)
    assert(filters.normalize({ lanes = true }) ~= nil, "flags alone are kept")
    assert(filters.same({ items = { "a" } }, { items = { "a", "", "" } }))
    assert(not filters.same({ items = { "a" } }, { items = { "a" }, exclude = true }))
  end,

  effective_specs = function()
    assert(filters.effective({ items = { "b", "a", "b" }, use = true }).items[1] == "a")
    assert(#filters.effective({ items = { "b", "a", "b" }, use = true }).items == 2)
    assert(filters.effective({ items = { "a" }, exclude = true, use = true }).exclude)
    local l = filters.effective({ items = { "a", "", "c" }, lanes = true, exclude = true, use = true })
    assert(l and l.lanes and l.left == "a" and l.right == nil and not l.exclude, "lanes: slots 1-2, whitelist")
    assert(filters.effective({ items = { "", "", "c" }, lanes = true, use = true }) == nil, "slot 3 does nothing per lane")
    assert(filters.effective({ items = { "a" }, use = false }) == nil, "Use filters off does nothing")
    assert(filters.effective({ items = { "a" } }) ~= nil, "a record from before Use filters is in use")
    assert(filters.normalize({ use = false }) == nil and filters.normalize({}) == nil, "defaults")
    assert(filters.effective({ items = { "gone" }, use = true }, function(n)
      return n ~= "gone"
    end) == nil, "removed items are dropped")
    assert(filters.signature({ false, false }, 2) == "")
    assert(filters.signature({ false, { items = { "a" } } }, 2) == "-;W:a")
  end,

  no_filter_is_the_plain_network = function()
    local a = network.build(3, 4, {})
    local b = network.build(3, 4, { filters = { false, false, false, false } })
    assert(a and b and #a.edges == #b.edges and not b.filtered)
  end,

  whitelist_is_exclusive = function()
    for _, recirc in ipairs({ true, false }) do
      local specs = { filters.effective(W("iron")), false, false }
      local net = assert(network.build(3, 3, { recirc = recirc, filters = specs }))
      check_ports(net)
      expect(net, "iron", "1")
      expect(net, "copper", "2 3")
    end
  end,

  same_item_on_two_blocks_is_shared = function()
    local specs = { filters.effective(W("iron")), filters.effective(W("iron", "gear")), false }
    local net = assert(network.build(2, 3, { filters = specs }))
    check_ports(net)
    expect(net, "iron", "1 2")
    expect(net, "gear", "2")
    expect(net, "stone", "3")
  end,

  blacklist_takes_the_rest = function()
    local specs = { filters.effective({ items = { "iron" }, exclude = true, use = true }), false, filters.effective(W("copper")) }
    local net = assert(network.build(4, 3, { filters = specs }))
    check_ports(net)
    expect(net, "iron", "2")
    expect(net, "copper", "3")
    expect(net, "stone", "1 2")
  end,

  item_nobody_takes_blocks = function()
    -- every output whitelists: the rest has nowhere to go
    local specs = { filters.effective(W("iron")), filters.effective(W("copper")) }
    local net = assert(network.build(2, 2, { filters = specs }))
    check_ports(net)
    expect(net, "stone", "dead")
    -- excluded everywhere
    specs = { filters.effective({ items = { "iron" }, exclude = true, use = true }) }
    net = assert(network.build(2, 1, { filters = specs }))
    check_ports(net)
    expect(net, "iron", "dead")
    expect(net, "copper", "1")
  end,

  lanes_put_each_item_on_its_lane = function()
    local specs = { filters.effective({ items = { "iron", "copper" }, lanes = true, use = true }), false }
    local net = assert(network.build(3, 2, { balance_lanes = true, filters = specs }))
    check_ports(net)
    expect(net, "iron", "1:L")
    expect(net, "copper", "1:R")
    expect(net, "stone", "2")
    -- one slot only, and the same item on both lanes
    specs = { filters.effective({ items = { "", "copper" }, lanes = true, use = true }), filters.effective({ items = { "iron", "iron" }, lanes = true, use = true }), false }
    net = assert(network.build(2, 3, { filters = specs }))
    check_ports(net)
    expect(net, "copper", "1:R")
    expect(net, "iron", "2:L 2:R")
    expect(net, "stone", "3")
  end,

  big_filtered_network_builds = function()
    local specs = {}
    for j = 1, 12 do
      specs[j] = j % 3 == 0 and filters.effective(W("i" .. j, "k" .. j)) or false
    end
    local net = assert(network.build(9, 12, { filters = specs }))
    check_ports(net)
    expect(net, "i3", "3")
    expect(net, "other", "1 10 11 2 4 5 7 8")
  end,
}
