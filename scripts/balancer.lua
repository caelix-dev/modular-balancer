-- Live balancing: turns each group of blocks (scripts/groups.lua) into a working balancer. A
-- refresh scans the group's ports (scripts/io.lua), swaps belt tiles for edges and places the
-- block-tile linked belts, builds the N:M network (scripts/network.lua) and places or rebuilds it
-- with the items carried over (scripts/builder.lua), then links every port to it.
--
-- storage.balancer = {
--   recs  = { [group id] = mb.Balancer },
--   dirty = { [group id] = player index (0 for none) },   groups to refresh at the next flush
--   sinks = { [group id] = { player_index?, robot? } },   who removed the last block of a group
--   loose = { [unit number] = LuaEntity },                 edges built by the game, not by this
--                                                           mod (an upgrade, a ghost, a clone)
-- }
--
-- Coalescing. Events only mark groups dirty (balancer.mark, mark_near, mark_block). The next
-- tick flushes them all at once (an on_nth_tick(1) handler that exists only while something is
-- dirty, re-set in on_load), so a bulk build or deconstruction refreshes each group once, not once
-- per entity. There is no per-tick script in the steady state.
--
-- A flush:
--   1. retires groups that no longer exist: their ports go to a pool, and their network goes to
--      the live group that now holds their blocks (a merge), or else to a live group on one of
--      their tiles (a block upgraded or replaced in place: its items move to the new tier's
--      network), or else to whoever removed the last block (a player's inventory, a robot's
--      logistic network, a space platform's hub; what does not fit is spilled), or else is
--      spilled next to the group (destroyed: nothing is deleted). Spills never land on a tile the
--      group occupied (a rebuild there would build over them) and are marked for the group's
--      robots (balancer.spill_clear);
--   2. refreshes each live dirty group: scan; if it has at least one input and one output, its
--      edges and block-tile linked belts are put in place (claimed), the network is rebuilt
--      only when N or M changed (or networks were merged in), and every port is linked. A group
--      without inputs or without outputs keeps its network, dormant, with its items, and has no
--      visible ports;
--   3. links shared tiles: the output network linked belt of one group straight to the input
--      network linked belt of the other (a tile between two blocks stays a plain belt, F1);
--   4. cleans the pool (and the loose edges): an edge no group claimed is swapped back to its
--      belt (items kept), a
--      block-tile linked belt no group claimed is removed and its items go into its group's
--      network buffer (or are spilled when there is none);
--   5. marks the groups around every tile whose belt-connectable is not what it was before the
--      flush (swapped, unswapped, a block-tile linked belt added, removed or turned), for the next
--      tick (F3 re-check triggers; e.g. an inserter port facing a tile that is a plain belt again
--      moves). Only net changes count: a tile swapped and swapped back in the same flush (a
--      failed rebuild, a group left without outputs) marks nothing, so a flush that cannot make
--      progress does not run again every tick.
-- Refusals (io.scan, a failed rebuild) are kept in the record; those not already there at the
-- last refresh are shown as flying text to the player whose action marked the group
-- (balancer.notify).
local groups = require("scripts.groups")
local network = require("scripts.network")
local builder = require("scripts.builder")
local belt_io = require("scripts.io")

local balancer = {}

---@class mb.Balancer
---@field placed table? the network (builder Placed), or nil
---@field extra table[] networks merged into this group that are not carried in yet
---@field n integer network inputs of `placed`
---@field m integer network outputs of `placed`
---@field inputs mb.IoPort[] linked to placed.inputs[i]
---@field outputs mb.IoPort[] linked to placed.outputs[j]
---@field units (integer|uint64)[] blocks at the last refresh
---@field tiles {[1]: integer, [2]: integer}[] their tiles (x, y) on anchor.surface_index
---@field force_index integer? the group's force
---@field anchor { surface_index: integer, position: MapPosition }?
---@field refused { reason: string, position: MapPosition }[]

local function state()
  storage.balancer = storage.balancer or { recs = {}, dirty = {} }
  local st = storage.balancer
  st.sinks = st.sinks or {}
  st.loose = st.loose or {}
  st.redirects = st.redirects or {}
  return st
end

local function arm()
  script.on_nth_tick(1, function()
    balancer.flush()
  end)
end

-- True while a flush has work to do: dirty groups, or loose edges to claim or swap back. The one
-- rule for the flush handler: arm() is called whenever this becomes true, flush() unregisters the
-- handler and empties both, and on_load re-arms from it, so a client joining (or a save loaded)
-- in such a tick registers the same handler as the players already in the game (MODDING-RULES
-- §2). Reads storage only.
---@param st table?
---@return boolean
function balancer.pending(st)
  return st ~= nil and (next(st.dirty) ~= nil or (st.loose ~= nil and next(st.loose) ~= nil)
    or (st.redirects ~= nil and next(st.redirects) ~= nil))
end

-- on_load: re-sets the flush handler when a save was made with work pending.
function balancer.on_load()
  if balancer.pending(storage.balancer) then
    arm()
  end
end

-- Marks groups for the next flush. `player_index` is the player whose action changed them.
---@param ids integer[]
---@param gone integer[]?
---@param player_index integer?
function balancer.mark(ids, gone, player_index)
  local st = state()
  local any = false
  for _, list in ipairs({ ids, gone or {} }) do
    for _, id in ipairs(list) do
      st.dirty[id] = player_index or st.dirty[id] or 0
      any = true
    end
  end
  if any then
    arm()
  end
end

-- Marks the groups of the blocks on tiles x1..x2, y1..y2 of surface `si`.
local function mark_tiles(si, x1, y1, x2, y2, player_index)
  local ids = {}
  for x = x1, x2 do
    for y = y1, y2 do
      local unit = groups.block_at(si, x, y)
      if unit then
        ids[#ids + 1] = groups.of(unit)
      end
    end
  end
  balancer.mark(ids, nil, player_index)
end

-- A block was built or removed at `entity`'s tile: the groups two tiles away in a straight line
-- may share a belt tile with it.
---@param entity LuaEntity
function balancer.mark_block(entity, player_index)
  local x, y = belt_io.tiles_of(entity)
  balancer.mark_block_at(entity.surface_index, x, y, player_index)
end

-- The same for a block that was on tile (x, y) of surface `si` (a block destroyed without an
-- event, or teleported away).
function balancer.mark_block_at(si, x, y, player_index)
  local ids = {}
  for _, o in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
    local unit = groups.block_at(si, x + o[1], y + o[2])
    if unit then
      ids[#ids + 1] = groups.of(unit)
    end
  end
  balancer.mark(ids, nil, player_index)
end

-- A belt-connectable or an inserter changed (built, removed, rotated, flipped, pasted): marks
-- the groups it can affect. A belt changes the shape of belts up to two tiles away (curves,
-- side loading), and an inserter reaches belt_io.reach() tiles.
-- Marks the groups of the blocks within `r` tiles of tile (x, y) of surface `si`.
function balancer.mark_around(si, x, y, r, player_index)
  mark_tiles(si, x - r, y - r, x + r, y + r, player_index)
end

---@param entity LuaEntity
function balancer.mark_near(entity, player_index)
  local r = entity.type == "inserter" and belt_io.reach() or 2
  local x1, y1, x2, y2 = belt_io.tiles_of(entity)
  mark_tiles(entity.surface_index, x1 - r, y1 - r, x2 + r, y2 + r, player_index)
end

-- The balancer record of a group (tests and later tasks), or nil.
---@param id integer?
---@return mb.Balancer?
function balancer.get(id)
  return id and state().recs[id] or nil
end

-- Shows refusals as flying text to the player. A module field, so a test can watch it.
---@param player_index integer?
---@param refused { reason: string, position: MapPosition }[]
---@param surface_index integer
function balancer.notify(player_index, refused, surface_index)
  local player = player_index and player_index > 0 and game.get_player(player_index)
  if not (player and player.valid) then
    return
  end
  for _, r in ipairs(refused) do
    player.create_local_flying_text({ text = { "mb-message." .. r.reason }, position = r.position, surface = surface_index })
  end
end

local function link(a, b)
  if a.valid and b and b.valid and a.linked_belt_neighbour ~= b then
    a.connect_linked_belts(b)
  end
end

-- Remembers tile (x, y) of surface `s`, which a swap, an unswap or a port change is about to
-- change, with what stands there now (the first time in this flush). After the flush, the ports
-- around it are re-checked on the next tick if it ended up different (F3 re-check triggers).
---@param s LuaSurface
local function touch_tile(ctx, s, x, y)
  local key = s.index .. ":" .. x .. ":" .. y
  if not ctx.touched[key] then
    ctx.touched[key] = { s = s, x = x, y = y, before = belt_io.tile_signature(s, x, y) }
  end
end

-- The same for the tile of `e` (valid).
local function touch(ctx, e)
  local x, y = belt_io.tiles_of(e)
  touch_tile(ctx, e.surface, x, y)
end

local function claim(ctx, e, gid)
  ctx.claimed[e.unit_number] = true
  ctx.pool[#ctx.pool + 1] = { entity = e, gid = gid }
end

-- Puts the visible entity of an edge, tile or inserter port in place. Returns false when it
-- cannot (the port is then dropped).
---@param port mb.IoPort
---@param g mb.Group
local function realize(ctx, port, g, s, refused)
  local gid = g.id
  if port.kind == "shared" then
    return true
  end
  if port.kind == "edge" then
    local e = port.entity
    if not (e and e.valid) then
      return false
    end
    local _, role = belt_io.edge_belt(e.name)
    -- an edge built by the game (an upgrade, a ghost) may carry the wrong linked belt type
    if role == port.role and e.linked_belt_type == (role == "in" and "input" or "output") then
      claim(ctx, e, gid)
      port.visible = e
      return true
    end
    touch(ctx, e)
    if belt_io.edge_belt(e.name) then
      e = belt_io.unswap(e) -- rotated edge: back to its belt, then swapped with the right role
    end
    local edge = belt_io.swap(e, port.role)
    if not edge then
      return false
    end
    claim(ctx, edge, gid)
    port.visible = edge
    return true
  end
  local name = "mb-hidden-linked-belt-" .. g.tier
  local ltype = port.role == "in" and "input" or "output"
  local dirs
  if port.kind == "tile" then
    dirs = { port.role == "in" and belt_io.OPPOSITE[port.side] or port.side }
  else
    dirs = belt_io.SIDES
  end
  touch_tile(ctx, s, port.bx, port.by)
  local e, leftover = belt_io.block_port(s, port.bx, port.by, name, ltype, dirs, g.force)
  if leftover then
    ctx.leftovers[#ctx.leftovers + 1] = { inv = leftover, gid = gid, surface = s, position = { x = port.bx + 0.5, y = port.by + 0.5 } }
  end
  if not e then
    refused[#refused + 1] = { reason = "no-free-side", position = { x = port.bx + 0.5, y = port.by + 0.5 } }
    return false
  end
  claim(ctx, e, gid)
  port.visible = e
  return true
end

local function unclaim(ctx, ports)
  for _, p in ipairs(ports) do
    if p.visible and p.visible.valid then
      ctx.claimed[p.visible.unit_number] = nil
    end
    p.visible = nil
  end
end

-- A group that no longer exists: see the header, step 1.
local function retire(st, id, ctx, live)
  local rec = st.recs[id]
  if not rec then
    return
  end
  st.recs[id] = nil
  ---@type integer?
  local target
  for _, u in ipairs(rec.units) do
    local gid = groups.of(u)
    if gid and groups.get(gid) then
      target = gid
      break
    end
  end
  if not target and rec.anchor then
    for _, t in ipairs(rec.tiles or {}) do
      local unit = groups.block_at(rec.anchor.surface_index, t[1], t[2])
      local gid = unit and groups.of(unit)
      if gid and groups.get(gid) then
        target = gid
        break
      end
    end
  end
  for _, list in ipairs({ rec.inputs, rec.outputs }) do
    for _, p in ipairs(list) do
      if p.visible and p.visible.valid then
        ctx.pool[#ctx.pool + 1] = { entity = p.visible, gid = target, tiles = rec.tiles, sink = st.sinks[id], force_index = rec.force_index }
      end
    end
  end
  local nets = {}
  if rec.placed then
    nets[1] = rec.placed
  end
  for _, p in ipairs(rec.extra) do
    nets[#nets + 1] = p
  end
  if #nets == 0 then
    return
  end
  if target then
    ctx.donors[target] = ctx.donors[target] or {}
    for _, p in ipairs(nets) do
      table.insert(ctx.donors[target], p)
    end
    if not live.set[target] then
      live.set[target] = true
      live[#live + 1] = target
    end
  else
    ctx.spills[#ctx.spills + 1] = { nets = nets, anchor = rec.anchor, sink = st.sinks[id], tiles = rec.tiles, force_index = rec.force_index }
  end
end

-- A live group: see the header, step 2.
local function refresh_group(st, gid, ctx, player_index)
  local g = groups.get(gid) --[[@as mb.Group]]
  local rec = st.recs[gid]
  if not rec then
    rec = { extra = {}, n = 0, m = 0, inputs = {}, outputs = {}, units = {}, refused = {} }
    st.recs[gid] = rec
  end
  for _, p in ipairs(ctx.donors[gid] or {}) do
    rec.extra[#rec.extra + 1] = p
  end
  for _, list in ipairs({ rec.inputs, rec.outputs }) do
    for _, p in ipairs(list) do
      if p.visible and p.visible.valid then
        ctx.pool[#ctx.pool + 1] = { entity = p.visible, gid = gid }
      end
    end
  end

  local s = game.get_surface(g.surface_index) --[[@as LuaSurface]]
  local scan = belt_io.scan(g)
  local refused = scan.refused
  local inputs, outputs = {}, {}
  if #scan.inputs > 0 and #scan.outputs > 0 then
    -- edges and block-tile interfaces first: the inserter ports' facing depends on them
    local all = {}
    for _, p in ipairs(scan.inputs) do
      all[#all + 1] = p
    end
    for _, p in ipairs(scan.outputs) do
      all[#all + 1] = p
    end
    local ok = {}
    for pass = 1, 2 do
      for _, p in ipairs(all) do
        if (p.kind == "inserter") == (pass == 2) then
          ok[p] = realize(ctx, p, g, s, refused)
        end
      end
    end
    for _, p in ipairs(scan.inputs) do
      if ok[p] then
        inputs[#inputs + 1] = p
      end
    end
    for _, p in ipairs(scan.outputs) do
      if ok[p] then
        outputs[#outputs + 1] = p
      end
    end
    if #inputs == 0 or #outputs == 0 then
      unclaim(ctx, inputs)
      unclaim(ctx, outputs)
      inputs, outputs = {}, {}
    end
  end

  ---@type LuaEntity?
  local anchor_entity
  for _, e in pairs(g.blocks) do
    if e.valid then
      anchor_entity = e
      break
    end
  end
  if anchor_entity then
    rec.anchor = { surface_index = g.surface_index, position = anchor_entity.position }
    rec.force_index = g.force_index
  end

  local n, m = #inputs, #outputs
  if n > 0 and m > 0 then
    if not rec.placed or rec.n ~= n or rec.m ~= m or #rec.extra > 0 then
      local net = assert(network.build(n, m))
      local placed, err
      if rec.placed then
        placed, err = builder.rebuild(rec.placed, net, g.tier, g.force, rec.extra)
      elseif #rec.extra > 0 then
        local rest = {}
        for i = 2, #rec.extra do
          rest[#rest + 1] = rec.extra[i]
        end
        placed, err = builder.rebuild(rec.extra[1], net, g.tier, g.force, rest)
      else
        placed, err = builder.place(net, g.tier, g.force)
      end
      if placed then
        rec.placed, rec.extra, rec.n, rec.m = placed, {}, n, m
      else
        log("modular-balancer: group " .. gid .. " " .. n .. ":" .. m .. " not rebuilt: " .. tostring(err))
        refused[#refused + 1] = { reason = err == "too-many-items" and "too-many-items" or "rebuild-failed",
          position = rec.anchor and rec.anchor.position or { x = 0, y = 0 } }
        if rec.placed then
          -- keep the old network: link only as many ports as it has
          for i = #inputs, rec.n + 1, -1 do
            unclaim(ctx, { table.remove(inputs, i) })
          end
          for j = #outputs, rec.m + 1, -1 do
            unclaim(ctx, { table.remove(outputs, j) })
          end
        else
          unclaim(ctx, inputs)
          unclaim(ctx, outputs)
          inputs, outputs = {}, {}
        end
      end
    end
    if rec.placed then
      for i, p in ipairs(inputs) do
        if p.visible then
          link(p.visible, rec.placed.inputs[i])
        end
      end
      for j, p in ipairs(outputs) do
        if p.visible then
          link(p.visible, rec.placed.outputs[j])
        end
      end
      builder.compact(rec.placed)
    end
  end

  -- only refusals that were not there at the last refresh are shown again
  local shown = {}
  for _, r in ipairs(rec.refused) do
    shown[r.reason .. "@" .. r.position.x .. "," .. r.position.y] = true
  end
  local fresh = {}
  for _, r in ipairs(refused) do
    if not shown[r.reason .. "@" .. r.position.x .. "," .. r.position.y] then
      fresh[#fresh + 1] = r
    end
  end
  rec.inputs, rec.outputs, rec.refused = inputs, outputs, refused
  local units, tiles = {}, {}
  for u in pairs(g.blocks) do
    units[#units + 1] = u
    local _, x, y = groups.where(u)
    if x then
      tiles[#tiles + 1] = { x, y }
    end
  end
  rec.units, rec.tiles = units, tiles
  ctx.refreshed[#ctx.refreshed + 1] = gid
  if #fresh > 0 then
    balancer.notify(player_index, fresh, g.surface_index)
  end
end

-- Step 3: links each shared tile of the refreshed groups to the network on its other side.
local function link_shared(st, ctx)
  for _, gid in ipairs(ctx.refreshed) do
    local rec = st.recs[gid]
    if rec and rec.placed then
      for _, side in ipairs({ { mine = rec.outputs, theirs = "inputs", own = "outputs" }, { mine = rec.inputs, theirs = "outputs", own = "inputs" } }) do
        for k, p in ipairs(side.mine) do
          if p.kind == "shared" then
            local other = st.recs[groups.of(p.far) or 0]
            if other and other.placed then
              for i, q in ipairs(other[side.theirs]) do
                if q.kind == "shared" and q.tx == p.tx and q.ty == p.ty then
                  link(rec.placed[side.own][k], other.placed[side.theirs][i])
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Puts loose port items into group `gid`'s network buffer, or spills them.
-- With no network to take them (the group is gone, or its buffer is full), they go like a
-- removed group's network: to the sink of `entry` (who mined the last block), else spilled off
-- the group's tiles (`entry.tiles`, or the live group's), marked for its force's robots.
local function home(st, inv, gid, s, position, entry)
  local rec = gid and st.recs[gid]
  if rec and rec.placed and builder.stash(rec.placed, inv) then
    inv.destroy()
  else
    entry = entry or {}
    local fi = entry.force_index or (rec and rec.force_index)
    balancer.give(inv, entry.sink, s, position, entry.tiles or (rec and rec.tiles), fi and game.forces[fi] or nil)
  end
end

-- Step 4.
local function cleanup(st, ctx)
  local loose = {}
  for unit, e in pairs(st.loose) do
    if e.valid then
      loose[#loose + 1] = { unit = unit, entity = e }
    end
  end
  table.sort(loose, function(a, b) return a.unit < b.unit end)
  for _, l in ipairs(loose) do
    -- a loose block-tile linked belt (a clone) that no port claims empties into the network of
    -- the group on its tile, if any
    local e = l.entity
    local x, y = belt_io.tiles_of(e)
    local unit = groups.block_at(e.surface_index, x, y)
    local gid = unit and groups.of(unit)
    ctx.pool[#ctx.pool + 1] = { entity = e, gid = gid, tiles = { { x, y } } }
  end
  st.loose = {}
  for _, entry in ipairs(ctx.pool) do
    local e = entry.entity
    if e.valid and not ctx.claimed[e.unit_number] then
      touch(ctx, e)
      if belt_io.edge_belt(e.name) then
        belt_io.unswap(e)
      else
        local s, pos = e.surface, e.position
        local inv = belt_io.take_items(e)
        e.destroy()
        home(st, inv, entry.gid, s, pos, entry)
      end
    end
  end
  for _, l in ipairs(ctx.leftovers) do
    home(st, l.inv, l.gid, l.surface, l.position)
  end
end

-- Refreshes every dirty group now (see the header). Called by the on_nth_tick(1) handler, and by
-- tests that do not want to wait a tick.
function balancer.flush()
  local st = state()
  -- upgrade orders whose target was an edge (scripts/lifecycle.lua): an order placed inside
  -- on_marked_for_upgrade does not hold (measured), so it is placed here, a tick later
  local redirects = st.redirects
  st.redirects = {}
  for _, r in ipairs(redirects) do
    local e = r.entity
    if e.valid then
      e.cancel_upgrade(e.force)
      if r.target then
        local player = r.player_index and game.get_player(r.player_index) or nil
        e.order_upgrade({ target = r.target, force = e.force, player = player })
      end
    end
  end
  -- unregistered only now: the redirects above raise upgrade events whose handlers mark groups
  -- dirty (and register the handler again); those groups are flushed below, in this same call
  script.on_nth_tick(1, nil)
  local dirty = st.dirty
  st.dirty = {}
  local ids = {}
  for id in pairs(dirty) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local ctx = { pool = {}, claimed = {}, donors = {}, spills = {}, refreshed = {}, leftovers = {}, touched = {} }
  local live = { set = {} } -- array of group ids, and their set
  for _, id in ipairs(ids) do
    if groups.get(id) then
      live.set[id] = true
      live[#live + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    if not groups.get(id) then
      retire(st, id, ctx, live)
    end
  end
  for _, id in ipairs(live) do
    refresh_group(st, id, ctx, dirty[id])
  end
  link_shared(st, ctx)
  cleanup(st, ctx)
  -- F3: a tile swapped into an edge or back, or a block-tile linked belt that changed, can
  -- change the ports next to it (a port facing a tile that is a plain belt again, a belt whose
  -- shape changed). Their groups are flushed again on the next tick, but only for tiles that
  -- really differ now: a flush that put everything back as it was marks nothing.
  local keys = {}
  for key in pairs(ctx.touched) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local t = ctx.touched[key] --[[@as { s: LuaSurface, x: integer, y: integer, before: string }]]
    if t.s.valid and belt_io.tile_signature(t.s, t.x, t.y) ~= t.before then
      mark_tiles(t.s.index, t.x - 1, t.y - 1, t.x + 1, t.y + 1)
    end
  end
  for _, sp in ipairs(ctx.spills) do
    local a = sp.anchor
    local s = a and game.get_surface(a.surface_index)
    for _, p in ipairs(sp.nets) do
      if s then
        local invs = builder.take(p)
        for _, inv in ipairs(invs) do
          balancer.give(inv, sp.sink, s, a.position, sp.tiles, sp.force_index and game.forces[sp.force_index])
        end
      else
        builder.destroy(p) -- the surface is gone, and its blocks and belts with it
      end
    end
  end
  st.sinks = {}
end

-- Spills every stack of `inv` (a script inventory, destroyed) on the ground near `position` of
-- `s`, but never on one of `tiles` ({x, y} list: the tiles the group occupied), so a block rebuilt
-- there (a robot rebuilding death ghosts, a script reviving ghosts) cannot build over the items
-- and delete them. Each stack is dropped whole on the nearest free tile outside `tiles`, searched
-- ring by ring from `position`; the items are marked to be looted and, with `force`, for
-- deconstruction by that force, so its robots pick them up.
---@param inv LuaInventory
---@param s LuaSurface
---@param position MapPosition
---@param tiles {[1]: integer, [2]: integer}[]?
---@param force LuaForce?
function balancer.spill_clear(inv, s, position, tiles, force)
  local taken = {}
  for _, t in ipairs(tiles or {}) do
    taken[t[1] .. "," .. t[2]] = true
  end
  local cx = math.floor((position.x or position[1]) --[[@as number]])
  local cy = math.floor((position.y or position[2]) --[[@as number]])
  -- candidate tiles, nearest first, outside the group (up to 32 rings)
  local r, k, ring = 0, 0, {}
  local function next_tile()
    while true do
      k = k + 1
      if k > #ring then
        r = r + 1
        if r > 32 then
          return nil
        end
        ring, k = {}, 1
        for dx = -r, r do
          for dy = -r, r do
            if math.max(math.abs(dx), math.abs(dy)) == r then
              ring[#ring + 1] = { cx + dx, cy + dy }
            end
          end
        end
      end
      local t = ring[k] --[[@as {[1]: integer, [2]: integer}]]
      if not taken[t[1] .. "," .. t[2]] then
        return t
      end
    end
  end
  local tile = next_tile()
  for i = 1, #inv do
    local st = inv[i] --[[@as LuaItemStack]]
    local placed = false
    while st.valid_for_read and not placed and tile do
      local made = s.spill_item_stack({
        position = { tile[1] + 0.5, tile[2] + 0.5 }, stack = st, enable_looted = true, allow_belts = false,
        drop_full_stack = true, force = force, max_radius = 0.5, use_start_position_on_failure = false,
      })
      if #made > 0 then
        placed = true
      else
        tile = next_tile()
      end
    end
    if st.valid_for_read and not placed then
      -- no free tile within 32 rings: never drop the stack
      s.spill_item_stack({ position = position, stack = st, enable_looted = true, allow_belts = false, drop_full_stack = true, force = force })
    end
    st.clear()
  end
  inv.destroy()
end

-- Gives the items of `inv` (a script inventory, destroyed) to `sink`:
--   player     its main inventory (a player without one, dead or a spectator by the flush, is
--              skipped);
--   robot      the storage chests of its logistic network;
--   platform   its hub.
-- What does not fit, or everything with no sink, is spilled by balancer.spill_clear outside the
-- group's `tiles`, marked for deconstruction by the robot's or platform's force, or else by
-- `force` (the group's).
---@param inv LuaInventory
---@param sink { player_index: integer?, robot: LuaEntity?, platform: LuaSpacePlatform? }?
---@param s LuaSurface
---@param position MapPosition
---@param tiles {[1]: integer, [2]: integer}[]?
---@param force LuaForce?
function balancer.give(inv, sink, s, position, tiles, force)
  local player = sink and sink.player_index and game.get_player(sink.player_index) or nil
  local main = player and player.valid and player.get_main_inventory() or nil
  local robot = sink and sink.robot
  local platform = sink and sink.platform
  ---@type LuaLogisticNetwork?
  local net
  ---@type LuaEntity?
  local hub
  if robot and robot.valid then
    net = robot.logistic_network
    force = robot.force --[[@as LuaForce]]
  elseif platform and platform.valid then
    hub = platform.hub
    force = platform.force
  end
  for i = 1, #inv do
    local st = inv[i] --[[@as LuaItemStack]]
    if st.valid_for_read then
      local n = 0
      if main and main.valid then
        n = main.insert(st)
      elseif net and net.valid then
        n = net.insert(st, "storage")
      elseif hub and hub.valid then
        n = hub.insert(st)
      end
      if n >= st.count then
        st.clear()
      elseif n > 0 then
        st.count = st.count - n
      end
    end
  end
  balancer.spill_clear(inv, s, position, tiles, force)
end

-- Remembers who removed the last block of the `gone` groups (scripts/events.lua, a mined block):
-- a player, a robot or a space platform.
---@param gone integer[]
---@param player_index integer?
---@param robot LuaEntity?
---@param platform LuaSpacePlatform?
function balancer.set_sink(gone, player_index, robot, platform)
  if not (player_index or robot or platform) then
    return
  end
  local st = state()
  for _, id in ipairs(gone) do
    st.sinks[id] = { player_index = player_index, robot = robot, platform = platform }
  end
end

-- An edge built by the game, not by this mod (a ghost revived, an upgrade, a clone, an old
-- blueprint): the next flush keeps it if a group claims it, else swaps it back to its belt.
---@param e LuaEntity
---@param player_index integer?
function balancer.add_loose(e, player_index)
  state().loose[e.unit_number] = e
  if belt_io.edge_belt(e.name) then
    belt_io.dress(e) -- the game built it without the drawn half; it goes with the edge if unclaimed
  end
  balancer.mark_near(e, player_index)
  arm()
end

-- An upgrade order on `e` that targets an edge (scripts/lifecycle.lua): the next flush cancels it
-- and, when `target` ({ name, quality }) is given, orders `target` instead.
---@param e LuaEntity
---@param target { name: string, quality: string }?
---@param player_index integer?
function balancer.redirect_upgrade(e, target, player_index)
  local st = state()
  st.redirects[#st.redirects + 1] = { entity = e, target = target, player_index = player_index }
  arm()
end

-- Marks every group (configuration change, a lost hidden surface).
function balancer.mark_all()
  local ids = {}
  for id in pairs(storage.groups and storage.groups.by_id or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  balancer.mark(ids)
end

-- The hidden surface is about to go (deleted or cleared by another mod or a command): every
-- network's items are spilled at its group, the networks are dropped, and every group is marked,
-- so the next flush places new networks on a new surface. Nothing is deleted.
function balancer.drop_networks()
  local st = state()
  local ids = {}
  for id in pairs(st.recs) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local rec = st.recs[id]
    local nets = { table.unpack(rec.extra) }
    if rec.placed then
      table.insert(nets, 1, rec.placed)
    end
    local a = rec.anchor
    local s = a and game.get_surface(a.surface_index)
    for _, p in ipairs(nets) do
      if s and s.valid then
        for _, inv in ipairs((builder.take(p))) do
          balancer.spill_clear(inv, s, a.position, rec.tiles, rec.force_index and game.forces[rec.force_index])
        end
      else
        builder.destroy(p)
      end
    end
    rec.placed, rec.extra, rec.n, rec.m = nil, {}, 0, 0
  end
  balancer.mark_all()
end

-- Marks group `id` and flushes at once (the interface of the plan; events mark and let the next
-- tick flush).
---@param id integer
---@param player_index integer?
function balancer.refresh(id, player_index)
  balancer.mark({ id }, nil, player_index)
  balancer.flush()
end

return balancer
