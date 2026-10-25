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
--   jobs  = { [group id] = job },                          staged rebuilds ("Staged rebuilds")
--   drains = { [group id] = true },                        groups whose old networks drain
--   spill_queue = { { nets, anchor, sink, tiles, force_index, cursor } },  removed networks
--                                                           being taken out and given away
--   retry = { [group id] = true },                         marked by an event since the last
--                                                           flush (a failed staged rebuild is
--                                                           tried again)
-- }
--
-- Bounded work (Plan 3 Task 5): the handler spends balancer.tick_budget work units per tick on
-- scans, rebuilds, drains and spills; what does not fit waits for the next tick.
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
--      only when N or M changed, networks were merged in, or the group's settings (balance
--      lanes, redistribute unused shares; scripts/groups.lua, scripts/gui.lua) differ from those
--      the network was built with, and every port is linked. A group
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

-- Called at the end of every flush with the ids of the refreshed groups (set by scripts/gui.lua).
---@param _ integer[]
function balancer.after_flush(_) end

---@class mb.Balancer
---@field placed table? the network (builder Placed), or nil
---@field extra table[] networks merged into this group that are not carried in yet
---@field draining table[]? old networks, sealed, whose items are moving into `placed` (staged)
---@field failed string? the shape (job_key) whose staged placement failed, not retried until the
---  group changes shape or is marked by an event
---@field failed_err string?
---@field player_index integer? the last player whose action refreshed the group
---@field stuck_shown boolean? a stuck drain's refusal was shown
---@field n integer network inputs of `placed`
---@field m integer network outputs of `placed`
---@field lanes boolean? `placed` has lane splitters (nil: no, a network from an older save)
---@field recirc boolean? `placed` recirculates (nil: yes, a network from an older save)
---@field inputs mb.IoPort[] linked to placed.inputs[i]
---@field outputs mb.IoPort[] linked to placed.outputs[j]
---@field units (integer|uint64)[] blocks at the last refresh
---@field tiles {[1]: integer, [2]: integer}[] their tiles (x, y) on anchor.surface_index
---@field force_index integer? the group's force
---@field anchor { surface_index: integer, position: MapPosition }?
---@field refused { reason: string, position: MapPosition }[]

-- Work units (builder.COST) the flush handler spends per tick on rebuilds, drains and spills.
-- About 30 ms on a desktop. Generating a network cannot be split, so a tick that generates one
-- can take longer (64:65: about 90 ms). A module constant, the same on every peer; tests lower it.
balancer.tick_budget = 30000

local function state()
  storage.balancer = storage.balancer or { recs = {}, dirty = {} }
  local st = storage.balancer
  st.sinks = st.sinks or {}
  st.loose = st.loose or {}
  st.redirects = st.redirects or {}
  st.jobs = st.jobs or {}
  st.drains = st.drains or {}
  st.spill_queue = st.spill_queue or {}
  st.retry = st.retry or {}
  st.stuck = st.stuck or {}
  st.loose_retired = st.loose_retired or {}
  return st
end

local function arm()
  script.on_nth_tick(1, function()
    balancer.flush(balancer.tick_budget)
  end)
end

-- Drains that got stuck (the new buffer full) are retried every STUCK_RETRY ticks while any is
-- stuck: their new network may have emptied its buffer by itself. Registered exactly while
-- st.stuck is non-empty: st.stuck gains entries only next to arm_stuck() and is emptied only by
-- the handler, which unregisters itself; on_load re-sets it from st.stuck (multiplayer: a client
-- that joins registers the same). Ids of groups gone or resumed meanwhile are harmless (the
-- drain step drops them). A drain whose new buffer stays full (outputs blocked for good) is
-- retried every STUCK_RETRY ticks for as long as that lasts; each retry merges the buffer once.
local STUCK_RETRY = 300
local function arm_stuck()
  script.on_nth_tick(STUCK_RETRY, function()
    local st = storage.balancer
    script.on_nth_tick(STUCK_RETRY, nil)
    for gid in pairs(st.stuck or {}) do
      st.drains[gid] = true
    end
    st.stuck = {}
    arm()
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
    or (st.redirects ~= nil and next(st.redirects) ~= nil) or balancer.working(st))
end

-- True while staged work remains: a network being placed (st.jobs), old networks draining into
-- a group's new one (st.drains), removed networks being taken out and given or spilled
-- (st.spill_queue). Reads storage only.
---@param st table?
---@return boolean
function balancer.working(st)
  return st ~= nil and ((st.jobs ~= nil and next(st.jobs) ~= nil) or (st.drains ~= nil and next(st.drains) ~= nil)
    or (st.spill_queue ~= nil and next(st.spill_queue) ~= nil))
end

-- on_load: re-sets the flush handler when a save was made with work pending.
function balancer.on_load()
  if balancer.pending(storage.balancer) then
    arm()
  end
  if storage.balancer and storage.balancer.stuck and next(storage.balancer.stuck) then
    arm_stuck()
  end
end

-- Marks groups for the next flush. `player_index` is the player whose action changed them.
---@param ids integer[]
---@param gone integer[]?
---@param player_index integer?
function balancer.mark(ids, gone, player_index, internal)
  local st = state()
  local any = false
  for _, list in ipairs({ ids, gone or {} }) do
    for _, id in ipairs(list) do
      st.dirty[id] = player_index or st.dirty[id] or 0
      if not internal then
        st.retry[id] = true
      end
      any = true
    end
  end
  if any then
    arm()
  end
end

-- Marks the groups of the blocks on tiles x1..x2, y1..y2 of surface `si`.
local function mark_tiles(si, x1, y1, x2, y2, player_index, internal)
  local ids = {}
  for x = x1, x2 do
    for y = y1, y2 do
      local unit = groups.block_at(si, x, y)
      if unit then
        ids[#ids + 1] = groups.of(unit)
      end
    end
  end
  balancer.mark(ids, nil, player_index, internal)
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
  if a and a.valid and b and b.valid and a.linked_belt_neighbour ~= b then
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

---@return mb.Balancer
local function new_rec()
  return { extra = {}, n = 0, m = 0, inputs = {}, outputs = {}, units = {}, tiles = {}, refused = {} } --[[@as mb.Balancer]]
end

-- Stops the staged placement of group `gid`'s new network, if any: what it created is removed
-- (it holds no items: a network is linked only once complete).
local function abort_job(st, gid)
  local job = st.jobs[gid]
  if job then
    if job.b then
      builder.abort(job.b)
    end
    st.jobs[gid] = nil
  end
end

-- Every network of a record: the working one, those merged in and not carried in yet, and the
-- old ones still draining into the working one.
---@param rec mb.Balancer
---@return table[]
local function nets_of(rec)
  local nets = {}
  if rec.placed then
    nets[1] = rec.placed
  end
  for _, list in ipairs({ rec.extra, rec.draining or {} }) do
    for _, p in ipairs(list) do
      nets[#nets + 1] = p
    end
  end
  return nets
end
balancer.nets_of = nets_of

-- A group that no longer exists: see the header, step 1.
local function retire(st, id, ctx, live)
  local rec = st.recs[id]
  if not rec then
    return
  end
  st.recs[id] = nil
  abort_job(st, id)
  st.drains[id] = nil
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
        ctx.pool[#ctx.pool + 1] = { entity = p.visible, gid = target, tiles = rec.tiles, sink = st.sinks[id], force_index = rec.force_index,
          retired = true }
      end
    end
  end
  local nets = nets_of(rec)
  if #nets == 0 then
    return
  end
  -- nothing flows in or out of them any more (a shared tile could still link one to a live
  -- group): they are carried into the target, or taken out and given away, over several ticks
  for _, p in ipairs(nets) do
    builder.seal(p)
  end
  if target then
    -- straight into the target's record: its refresh may wait for a later tick (budget)
    local trec = st.recs[target]
    if not trec then
      trec = new_rec()
      st.recs[target] = trec
    end
    if not trec.anchor then
      -- a record not refreshed yet (its refresh deferred): until it is, the retired group's place
      -- stands for it, so if it goes too its networks are found again or spilled there
      trec.anchor, trec.tiles, trec.force_index = rec.anchor, rec.tiles, rec.force_index
    end
    for _, p in ipairs(nets) do
      trec.extra[#trec.extra + 1] = p
    end
    if not live.set[target] then
      live.set[target] = true
      live[#live + 1] = target
    end
  else
    ctx.spills[#ctx.spills + 1] = { nets = nets, anchor = rec.anchor, sink = st.sinks[id], tiles = rec.tiles, force_index = rec.force_index }
  end
end

-- Staged rebuilds (Plan 3 Task 5, Review Focus 5: rebuild cost is bounded). A rebuild is a job
-- in st.jobs[gid] = { key, n, m, lanes, recirc, tier, force, player_index, b }:
--   1. generate and plan the network (network.build, builder.start): one tick, it cannot be
--      split; it starts only in a tick with budget left;
--   2. place it, a budget's worth of entities per tick (builder.advance). The old network keeps
--      running meanwhile with as many ports as it has; the new one holds no items and is not
--      linked, so aborting it (the group changed shape or is gone) loses nothing;
--   3. once complete it becomes the working network at once (finish_job): every port is linked
--      to it, and the old network and those merged in are sealed (builder.seal) and drain into
--      it, a budget's worth of items per tick (st.drains, builder.drain). Each item moves exactly
--      once, from a sealed network to the working one, so nothing is lost or duplicated whatever
--      the tick or save it is interrupted at.
-- A small rebuild fits in one tick and completes inside the flush that asked for it, as before.
-- Everything is in storage, and the budget is counted in work units, not time, so a save
-- made mid-rebuild loads and finishes it, and every peer of a multiplayer game does the same work
-- in the same tick.

-- Networks up to this many inputs and outputs are generated in any tick (a few milliseconds).
local SMALL = 16
-- Work units charged for scanning a group in a flush, per port found (64:65: about 11 ms).
local SCAN_COST = 80
-- Work units charged per edge swapped back to its belt by a flush.
local UNSWAP_COST = 150
-- Work units charged per stack given away or spilled when a removed network is taken out.
local SPILL_COST = 25

-- The shape a rebuild targets.
local function job_key(n, m, want)
  return n .. ":" .. m .. ":" .. tostring(want.lanes) .. ":" .. tostring(want.recirc)
end

-- The new network of group `gid` is complete: it becomes the working network, and the old one
-- and those merged in are sealed and drain into it.
local function finish_job(st, gid, job)
  local rec = st.recs[gid]
  st.jobs[gid] = nil
  rec.draining = rec.draining or {}
  local olds = {}
  if rec.placed then
    olds[1] = rec.placed
  end
  for _, p in ipairs(rec.extra) do
    olds[#olds + 1] = p
  end
  for _, p in ipairs(olds) do
    builder.seal(p)
    rec.draining[#rec.draining + 1] = p
  end
  rec.placed, rec.extra = job.b.placed, {}
  rec.n, rec.m, rec.lanes, rec.recirc = job.n, job.m, job.lanes, job.recirc
  rec.failed, rec.failed_err = nil, nil
  if #rec.draining > 0 then
    st.drains[gid] = true
  end
end

-- Runs group `gid`'s rebuild job within ctx.units. Returns "done" (the new network is working),
-- "pending" (more next tick) or "failed" and the error (nothing was kept of the new network).
local function run_job(st, gid, job, ctx)
  if ctx.units <= 0 then
    return "pending"
  end
  -- the group's force as it is now (forces merged since the job started: the old LuaForce is
  -- invalid, and the entities already placed have moved to the new force)
  local g = groups.get(gid)
  if g then
    job.force = g.force
    if job.b then
      job.b.placed.force = g.force
    end
  end
  if not (job.b or job.net) then
    -- generating cannot be split: a large network is generated only at the start of a tick's
    -- budget, so nothing else shares its tick
    if ctx.units < ctx.budget and math.max(job.n, job.m) > SMALL then
      return "pending"
    end
    if math.max(job.n, job.m) > SMALL then
      st.last_generated = game.tick
    end
    local net = assert(network.build(job.n, job.m, { balance_lanes = job.lanes, recirc = job.recirc }))
    job.net = net -- plain tables, kept until the next step plans it
    ctx.units = ctx.units - builder.COST.generate
      * (#net.splitters + #(net.priority or {}) + #(net.lane_splitters or {}) + 2 * #net.edges)
    if ctx.units <= 0 then
      return "pending"
    end
  end
  if not job.b then
    local b, err = builder.start(job.net, job.tier, job.force)
    job.net = nil
    if not b then
      st.jobs[gid] = nil
      return "failed", err
    end
    job.b = b
    ctx.units = ctx.units - builder.COST.plan * #b.ops
    if ctx.units <= 0 then
      return "pending"
    end
  end
  local done, used, err = builder.advance(job.b, ctx.units)
  ctx.units = ctx.units - used
  if done == nil then
    st.jobs[gid] = nil
    return "failed", err
  end
  if not done then
    return "pending"
  end
  finish_job(st, gid, job)
  return "done"
end

-- A live group: see the header, step 2.
local function refresh_group(st, gid, ctx, player_index)
  local g = groups.get(gid) --[[@as mb.Group]]
  local rec = st.recs[gid]
  if not rec then
    rec = new_rec()
    st.recs[gid] = rec
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
  ctx.units = ctx.units - SCAN_COST * (#scan.inputs + #scan.outputs)
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

  if player_index and player_index > 0 then
    rec.player_index = player_index -- shown a stuck drain's refusal later
  end
  local n, m = #inputs, #outputs
  local want = groups.settings(gid)
  local key = job_key(n, m, want)
  if rec.failed and (rec.failed ~= key or ctx.retry[gid]) then
    rec.failed, rec.failed_err = nil, nil
  end
  local job = st.jobs[gid]
  if job and (job.key ~= key or n == 0 or m == 0) then
    abort_job(st, gid) -- the group changed while its new network was being placed
    job = nil
  end
  if rec.draining and #rec.draining > 0 then
    st.drains[gid] = true -- also resumes a drain that got stuck (the new buffer was full)
    -- (st.stuck is cleared only by its handler, which unregisters itself at the same time, so
    -- the handler is registered exactly while st.stuck is non-empty, as on_load sets it)
  end
  if n > 0 and m > 0 then
    local stale = rec.placed and ((rec.lanes == true) ~= want.lanes or (rec.recirc ~= false) ~= want.recirc)
    if rec.placed and rec.n == n and rec.m == m and not stale then
      -- the network fits: networks merged in drain into it as it is
      if #rec.extra > 0 then
        rec.draining = rec.draining or {}
        for _, p in ipairs(rec.extra) do
          builder.seal(p)
          rec.draining[#rec.draining + 1] = p
        end
        rec.extra = {}
        st.drains[gid] = true
      end
    else
      local status, err
      if rec.failed == key then
        status, err = "failed", rec.failed_err -- a staged placement of this shape failed
      else
        if not job then
          st.job_seq = (st.job_seq or 0) + 1
          job = { key = key, n = n, m = m, lanes = want.lanes, recirc = want.recirc, tier = g.tier, force = g.force,
            player_index = player_index, seq = st.job_seq }
          st.jobs[gid] = job
        end
        status, err = run_job(st, gid, job, ctx)
      end
      if status == "failed" then
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
      -- "pending": every port stays claimed; the old network (if any) keeps running with as many
      -- of them as it has, linked below, and the rest are linked when the new one is complete
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
                -- while a rebuild is pending, a port beyond the old network's count has no
                -- network side yet: it is linked when the new network is complete (relink)
                local mine = rec.placed[side.own][k]
                if mine and q.kind == "shared" and q.tx == p.tx and q.ty == p.ty then
                  link(mine, other.placed[side.theirs][i])
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
    -- a removed group's edge deferred by an earlier flush stays deferrable (bounded work)
    ctx.pool[#ctx.pool + 1] = { entity = e, gid = gid, tiles = { { x, y } }, retired = st.loose_retired[l.unit] }
  end
  st.loose = {}
  st.loose_retired = {}
  for _, entry in ipairs(ctx.pool) do
    local e = entry.entity
    if e.valid and not ctx.claimed[e.unit_number] and entry.gid and ctx.deferred[entry.gid] then
      -- a port of a group whose refresh was deferred: left as it is, claimed or swapped back by
      -- a later flush
      st.loose[e.unit_number] = e
    elseif e.valid and not ctx.claimed[e.unit_number] and ctx.units <= 0 and entry.retired and belt_io.edge_belt(e.name) then
      -- out of budget (the ports of many removed groups): swapped back by a later flush. Only
      -- removed groups' edges: a live group's dropped port (a failed rebuild) is swapped back
      -- now, so its tile ends the flush as it began and nothing re-marks the group
      st.loose[e.unit_number] = e
      st.loose_retired[e.unit_number] = true
    elseif e.valid and not ctx.claimed[e.unit_number] then
      touch(ctx, e)
      if belt_io.edge_belt(e.name) then
        belt_io.unswap(e)
        ctx.units = ctx.units - UNSWAP_COST
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

---@param t table
---@return integer[]
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

-- A staged rebuild of group `gid` completed after the flush that scanned its ports: links them,
-- and its shared tiles, to the new network.
local function relink(st, gid)
  local rec = st.recs[gid]
  for i, p in ipairs(rec.inputs) do
    if p.visible then
      link(p.visible, rec.placed.inputs[i])
    end
  end
  for j, p in ipairs(rec.outputs) do
    if p.visible then
      link(p.visible, rec.placed.outputs[j])
    end
  end
  link_shared(st, { refreshed = { gid } })
end

-- Drains group `gid`'s old networks into its working network within ctx.units.
local function drain_group(st, gid, ctx)
  local rec = st.recs[gid]
  if not (rec and rec.placed and rec.draining and #rec.draining > 0) then
    st.drains[gid] = nil
    return
  end
  while #rec.draining > 0 do
    if ctx.units <= 0 then
      return
    end
    local status, used = builder.drain(rec.placed, rec.draining[1], ctx.units)
    ctx.units = ctx.units - used
    if status == "done" then
      table.remove(rec.draining, 1)
    elseif status == "stuck" then
      -- the new buffer is full (builder.max_buffer_slots): the rest waits, safe, in the sealed
      -- old network; retried every STUCK_RETRY ticks and at the group's next refresh. Shown once
      -- to the player whose action started it.
      st.drains[gid] = nil
      st.stuck[gid] = true
      arm_stuck()
      if not rec.stuck_shown then
        rec.stuck_shown = true
        log("modular-balancer: group " .. gid .. ": old network not emptied, the buffer is full")
        local r = { reason = "too-many-items", position = rec.anchor and rec.anchor.position or { x = 0, y = 0 } }
        if rec.anchor then
          balancer.notify(rec.player_index, { r }, rec.anchor.surface_index)
        end
      end
      return
    else
      return
    end
  end
  st.drains[gid] = nil
  rec.stuck_shown = nil
  builder.settle(rec.placed)
end

-- Where the networks of a removed record go: its anchor's surface and position. A missing anchor
-- (not expected: retire gives a fresh record the retired one's) is never taken for a lost
-- surface: the items go to the origin of surface 1 (always there), logged. Nil only when the
-- anchor's surface itself is gone (its blocks and belts with it).
---@return LuaSurface?, MapPosition?
local function spill_place(a)
  if not a then
    log("modular-balancer: a removed network has no place recorded; its items go to the origin of surface 1")
    return game.get_surface(1), { x = 0, y = 0 }
  end
  local s = game.get_surface(a.surface_index)
  if s and s.valid then
    return s, a.position
  end
  return nil, nil
end

-- Takes the networks of removed groups (st.spill_queue, from retire: no group took them) out
-- within ctx.units, and gives their items to whoever removed the last block, or spills them.
local function spill_some(st, ctx)
  while ctx.units > 0 and #st.spill_queue > 0 do
    local sp = st.spill_queue[1]
    local s, position = spill_place(sp.anchor)
    local p = sp.nets[1]
    if not p then
      table.remove(st.spill_queue, 1)
    elseif not s then
      builder.destroy(p) -- the surface is gone, and its blocks and belts with it
      table.remove(sp.nets, 1)
    else
      -- the take's share of the budget: every stack taken is given or spilled in this tick too
      local item = builder.COST.item
      local invs, _, gone, used = builder.take(p, ctx.units * item / (item + SPILL_COST))
      ctx.units = ctx.units - (used or 0)
      sp.cursor = sp.cursor or {}
      for _, inv in ipairs(invs) do
        ctx.units = ctx.units - SPILL_COST * (#inv - inv.count_empty_stacks())
        balancer.give(inv, sp.sink, s, position --[[@as MapPosition]], sp.tiles, sp.force_index and game.forces[sp.force_index], sp.cursor)
      end
      if gone ~= false then
        table.remove(sp.nets, 1)
      end
    end
  end
end

-- Runs group `gid`'s rebuild job outside its refresh (the staged work, or the fairness step at the
-- start of a flush) and handles every outcome: the one place a job that completes or fails after
-- its refresh is finished off.
local function step_job(st, gid, job, rec, ctx)
  local status, err = run_job(st, gid, job, ctx)
  if status == "done" then
    -- its ports and shared tiles were scanned at its last refresh: link them to the new network
    relink(st, gid)
    ctx.refreshed[#ctx.refreshed + 1] = gid
  elseif status == "failed" then
    -- the next flush keeps the old network, drops the ports it cannot take and shows the
    -- refusal; this shape is not tried again until the group changes or a player marks it
    log("modular-balancer: group " .. gid .. " " .. job.n .. ":" .. job.m .. " not rebuilt: " .. tostring(err))
    rec.failed, rec.failed_err = job.key, err
    balancer.mark({ gid }, nil, job.player_index, true)
  end
end

-- Rebuild jobs in the order they were started (fair: a group with a low id does not overtake).
---@return integer[]
local function jobs_in_order(st)
  local ids = sorted_keys(st.jobs)
  table.sort(ids, function(a, b)
    return (st.jobs[a].seq or 0) < (st.jobs[b].seq or 0) or ((st.jobs[a].seq or 0) == (st.jobs[b].seq or 0) and a < b)
  end)
  return ids
end

-- The staged work of a tick, within ctx.units: rebuild jobs (in the order they started), then
-- drains, then spills (group id order).
local function work(st, ctx)
  for _, gid in ipairs(jobs_in_order(st)) do
    if ctx.units <= 0 then
      return
    end
    local job = st.jobs[gid]
    local rec = st.recs[gid]
    if not (rec and groups.get(gid)) then
      abort_job(st, gid)
    elseif ctx.deferred and ctx.deferred[gid] then
      -- its refresh waits for a later tick (budget) and may change its shape: no work on a
      -- placement that may be dropped (review m3)
    else
      step_job(st, gid, job, rec, ctx)
    end
  end
  for _, gid in ipairs(sorted_keys(st.drains)) do
    if ctx.units <= 0 then
      return
    end
    drain_group(st, gid, ctx)
  end
  spill_some(st, ctx)
end

-- Refreshes every dirty group (see the header), then does staged work: rebuilds, drains and
-- spills (see "Staged rebuilds"). The on_nth_tick(1) handler calls it with balancer.tick_budget
-- work units; without a budget (tests, balancer.refresh) it finishes all staged work at once.
-- The handler stays registered while dirty groups, loose edges or staged work remain.
---@param budget number?
function balancer.flush(budget)
  local st = state()
  -- upgrade orders whose target was an edge (scripts/lifecycle.lua): an order placed inside
  -- on_marked_for_upgrade does not hold (measured), so it is placed here, a tick later; their
  -- upgrade events mark groups dirty, flushed below in this same call
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
  local dirty = st.dirty
  st.dirty = {}
  local retry = st.retry
  st.retry = {}
  local ids = sorted_keys(dirty)
  local ctx = { pool = {}, claimed = {}, spills = {}, refreshed = {}, leftovers = {}, touched = {},
    units = budget or math.huge, budget = budget or math.huge, retry = retry, deferred = {} }
  -- a large network waiting to be generated goes first, before any refresh, every other tick, so
  -- a steady stream of small refreshes (robots building near balancers) cannot starve it
  -- (review m1). Its group is not dirty now (a refresh may change its shape).
  if budget and st.last_generated ~= game.tick - 1 then
    for _, gid in ipairs(jobs_in_order(st)) do
      local job = st.jobs[gid] --[[@as table]]
      if not (job.b or job.net) and math.max(job.n, job.m) > SMALL and not dirty[gid] and st.recs[gid] and groups.get(gid) then
        step_job(st, gid, job, st.recs[gid], ctx)
        break
      end
    end
  end
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
    if ctx.units > 0 then
      refresh_group(st, id, ctx, dirty[id])
    else
      -- out of budget: refreshed on a later tick (still dirty)
      ctx.deferred[id] = true
      st.dirty[id] = dirty[id] or 0
      st.retry[id] = retry[id]
    end
  end
  link_shared(st, ctx)
  cleanup(st, ctx)
  -- F3: a tile swapped into an edge or back, or a block-tile linked belt that changed, can
  -- change the ports next to it (a port facing a tile that is a plain belt again, a belt whose
  -- shape changed). Their groups are flushed again on the next tick, but only for tiles that
  -- really differ now: a flush that put everything back as it was marks nothing.
  local keys = sorted_keys(ctx.touched)
  for _, key in ipairs(keys) do
    local t = ctx.touched[key] --[[@as { s: LuaSurface, x: integer, y: integer, before: string }]]
    if t.s.valid and belt_io.tile_signature(t.s, t.x, t.y) ~= t.before then
      mark_tiles(t.s.index, t.x - 1, t.y - 1, t.x + 1, t.y + 1, nil, true)
    end
  end
  for _, sp in ipairs(ctx.spills) do
    st.spill_queue[#st.spill_queue + 1] = sp
  end
  st.sinks = {}
  work(st, ctx)
  if not budget then
    -- everything at once (one pass does it all; a stuck drain or a failed job leaves the set)
    for _ = 1, 3 do
      if not balancer.working(st) then
        break
      end
      work(st, { units = math.huge, refreshed = ctx.refreshed })
    end
  end
  -- scripts/gui.lua: settings of refused rebuilds, open GUIs; with the groups refreshed here and
  -- those whose staged rebuild completed in this call
  balancer.after_flush(ctx.refreshed)
  if balancer.pending(st) then
    arm()
  else
    script.on_nth_tick(1, nil)
  end
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
---@param cursor { r: number?, k: number? }?
function balancer.spill_clear(inv, s, position, tiles, force, cursor)
  local taken = {}
  for _, t in ipairs(tiles or {}) do
    taken[t[1] .. "," .. t[2]] = true
  end
  local cx = math.floor((position.x or position[1]) --[[@as number]])
  local cy = math.floor((position.y or position[2]) --[[@as number]])
  -- candidate tiles, nearest first, outside the group (up to 32 rings); with a `cursor` (kept by
  -- the caller across calls: a removed network spilled over several ticks), the search goes on
  -- from where the last call stopped instead of trying the full tiles near the centre again
  ---@type number, number, {[1]: integer, [2]: integer}[]
  local r, k, ring = 0, 0, {}
  local function make_ring()
    ring = {}
    for dx = -r, r do
      for dy = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then
          ring[#ring + 1] = { cx + dx, cy + dy }
        end
      end
    end
  end
  if cursor and cursor.r then
    r, k = cursor.r, (cursor.k or 1) - 1
    make_ring()
  end
  -- a removed network spilled over several ticks may hold tens of thousands of stacks that do
  -- not merge: it gets more rings than one inventory (piling the rest on one spot costs more and
  -- more per stack)
  local rings = cursor and 256 or 32
  local function next_tile()
    while true do
      k = k + 1
      if k > #ring then
        r = r + 1
        if r > rings then
          return nil
        end
        make_ring()
        k = 1
      end
      local t = ring[k] --[[@as {[1]: integer, [2]: integer}]]
      -- never a tile that destroys what is dropped on it (a space platform's empty space)
      if not taken[t[1] .. "," .. t[2]] and not s.get_tile(t[1], t[2]).prototype.destroys_dropped_items then
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
      -- no free tile within the rings: never drop the stack (on a platform next to its hub, the
      -- middle of its foundation, rather than at a spot that may be over empty space)
      local hub = s.platform and s.platform.hub
      s.spill_item_stack({ position = hub and hub.valid and hub.position or position, stack = st, enable_looted = true, allow_belts = false,
        drop_full_stack = true, force = force })
    end
    st.clear()
  end
  if cursor then
    cursor.r, cursor.k = tile and r or rings + 1, tile and k or 1
  end
  inv.destroy()
end

-- Gives the items of `inv` (a script inventory, destroyed) to `sink`:
--   player     its main inventory (a player without one, dead or a spectator by the flush, is
--              skipped);
--   robot      the storage chests of its logistic network;
--   platform   its hub (also with no sink when `s` is a space platform's surface).
-- What does not fit, or everything with no sink, is spilled by balancer.spill_clear outside the
-- group's `tiles`, marked for deconstruction by the robot's or platform's force, or else by
-- `force` (the group's).
---@param inv LuaInventory
---@param sink { player_index: integer?, robot: LuaEntity?, platform: LuaSpacePlatform? }?
---@param s LuaSurface
---@param position MapPosition
---@param tiles {[1]: integer, [2]: integer}[]?
---@param force LuaForce?
---@param cursor table? see balancer.spill_clear
function balancer.give(inv, sink, s, position, tiles, force, cursor)
  local player = sink and sink.player_index and game.get_player(sink.player_index) or nil
  local main = player and player.valid and player.get_main_inventory() or nil
  local robot = sink and sink.robot
  local platform = sink and sink.platform
  if not (main or (robot and robot.valid) or (platform and platform.valid)) and s.platform then
    -- a group on a space platform with nobody to take its items: its hub (items spilled on a
    -- platform can land in space, where no robot fetches them)
    platform = s.platform
  end
  -- on a platform, what the sink does not take goes to the hub before anything is spilled
  local overflow = s.platform and s.platform.hub
  if overflow and not overflow.valid then
    overflow = nil
  end
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
      if st.valid_for_read and overflow and overflow ~= hub then
        local m = overflow.insert(st)
        if m >= st.count then
          st.clear()
        elseif m > 0 then
          st.count = st.count - m
        end
      end
    end
  end
  balancer.spill_clear(inv, s, position, tiles, force, cursor)
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

-- Configuration change: networks placed by an older version can be damaged (Plan 3 Task 5 sets
-- every hidden entity indestructible when it is created). Makes them indestructible too.
function balancer.harden()
  for _, rec in pairs(storage.balancer and storage.balancer.recs or {}) do
    for _, p in ipairs(nets_of(rec)) do
      for _, e in ipairs(p.entities) do
        if e.valid and e.destructible then
          e.destructible = false
        end
      end
    end
  end
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
-- Unbounded on purpose (review m7): it runs in the event before the hidden surface goes, so every
-- network must be out before the event returns. A rare admin or mod action.
function balancer.drop_networks()
  local st = state()
  local ids = {}
  for id in pairs(st.recs) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  -- removed groups' networks waiting to be given away, and new networks being placed, first
  spill_some(st, { units = math.huge })
  for _, id in ipairs(sorted_keys(st.jobs)) do
    abort_job(st, id)
  end
  st.drains = {}
  for _, id in ipairs(ids) do
    local rec = st.recs[id]
    local nets = nets_of(rec)
    local s, position
    if #nets > 0 then
      s, position = spill_place(rec.anchor)
    end
    for _, p in ipairs(nets) do
      if s then
        for _, inv in ipairs((builder.take(p))) do
          balancer.spill_clear(inv, s, position --[[@as MapPosition]], rec.tiles, rec.force_index and game.forces[rec.force_index])
        end
      else
        builder.destroy(p)
      end
    end
    rec.placed, rec.extra, rec.draining, rec.n, rec.m = nil, {}, nil, 0, 0
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
