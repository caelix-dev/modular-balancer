-- Spike S1 (throwaway): several belts per 1x1 block. Loaded only with the `mb-spikes`
-- startup setting. Nothing here is a product prototype.
--
-- The prototype-stage variants at the end of this file each make the game refuse to load;
-- they are selected with the `mb-spikes-variant` setting (see settings.lua) and run by
-- repro-load-errors.sh, which records the exact errors (docs/feasibility.md F1). Their
-- outcome: every belt-connectable prototype must collide with every other one, itself
-- included. The interfaces used by test.lua therefore keep the default belt mask; runtime
-- stacking is tested in test.lua.

-- Belt speed of the tier the spike measures: turbo with Space Age, else express.
local tier_belt = mods["space-age"] and "turbo-transport-belt" or "express-transport-belt"
local speed = data.raw["transport-belt"][tier_belt].speed

data:extend({ { type = "collision-layer", name = "mb_spike_core" } })

local protos = {}

-- The visible block: a building that is not belt-connectable and shares no layer with belts,
-- so hidden belt-connectable or container entities can sit on its tile.
local block = table.deepcopy(data.raw["simple-entity-with-owner"]["simple-entity-with-owner"])
block.name = "mb-spike-block"
block.collision_mask = { layers = { item = true, player = true, is_object = true } }
block.minable = nil
protos[#protos + 1] = block

-- (a) a linked belt interface (vanilla look) at the measured tier.
local lb = table.deepcopy(data.raw["linked-belt"]["linked-belt"])
lb.name = "mb-spike-lb"
lb.speed = speed
lb.minable = nil
lb.allow_side_loading = false
protos[#protos + 1] = lb

-- (b) a loader-1x1 interface whose container target is on its own tile.
local ld = table.deepcopy(data.raw["loader-1x1"]["loader-1x1"])
ld.name = "mb-spike-ld"
ld.speed = speed
ld.container_distance = 0
ld.minable = nil
protos[#protos + 1] = ld

-- (b) the core container the loaders of a tile share; not belt-connectable, own layer.
local core = table.deepcopy(data.raw["linked-container"]["linked-chest"])
core.name = "mb-spike-core"
core.collision_mask = { layers = { mb_spike_core = true } }
core.minable = nil
core.inventory_size = 48
protos[#protos + 1] = core

-- (c) the visible block itself as a belt-connectable entity: a linked belt that allows side
-- loading, so one entity has a back and two sides as belt faces.
local cb = table.deepcopy(lb)
cb.name = "mb-spike-cblock"
cb.allow_side_loading = true
protos[#protos + 1] = cb

-- (e) edge interface: the last tile of the player's own belt is swapped for a linked belt of
-- the same tier, drawn with the belt animation only (no structure sprites), so it still reads
-- as the player's belt. Declared to mine back to the belt item (measured in test.lua).
-- This one is used for input edges (side loading allowed, like the belt it replaces).
local edge = table.deepcopy(lb)
edge.name = "mb-spike-edge"
edge.structure = nil
edge.allow_side_loading = true
edge.minable = { mining_time = 0.1, result = tier_belt }
edge.placeable_by = { item = tier_belt, count = 1 }
edge.belt_animation_set = data.raw["transport-belt"][tier_belt].belt_animation_set
protos[#protos + 1] = edge

-- (e) output edge: no side loading, so a foreign belt pointing into its side cannot merge
-- items into a balancer output.
local edge_out = table.deepcopy(edge)
edge_out.name = "mb-spike-edge-out"
edge_out.allow_side_loading = false
protos[#protos + 1] = edge_out

-- (e) edge in the vanilla "transport-belt" fast-replace group (the vanilla linked belt is in
-- "linked-belts"), to measure what drag-building a belt over an edge does.
local edge_frg = table.deepcopy(edge)
edge_frg.name = "mb-spike-edge-frg"
edge_frg.fast_replaceable_group = "transport-belt"
protos[#protos + 1] = edge_frg

-- Test harness: a loader at the tier speed that feeds from / sinks into an adjacent chest.
local io_loader = table.deepcopy(data.raw["loader-1x1"]["loader-1x1"])
io_loader.name = "mb-spike-io-loader"
io_loader.speed = speed
io_loader.minable = nil
protos[#protos + 1] = io_loader

data:extend(protos)

-- Prototype-stage variants (each one is expected to stop the game from loading).
local variant = settings.startup["mb-spikes-variant"].value
local SIDES = { "n", "e", "s", "w" }
local function linked_belts_with(mask_for_side)
  local v = {}
  for _, side in ipairs(SIDES) do
    local p = table.deepcopy(lb)
    p.name = "mb-spike-var-lb-" .. side
    p.collision_mask = mask_for_side(side)
    v[#v + 1] = p
  end
  data:extend(v)
end

if variant == "custom-layers" then
  -- One custom layer per side.
  for _, side in ipairs(SIDES) do
    data:extend({ { type = "collision-layer", name = "mb_spike_" .. side } })
  end
  linked_belts_with(function(side) return { layers = { ["mb_spike_" .. side] = true } } end)
elseif variant == "belt-layer-subsets" then
  -- A different layer of the vanilla belt mask per side: each collides with transport belts,
  -- no two sides share a layer.
  local layer = { n = "floor", e = "meltable", s = "transport_belt", w = "water_tile" }
  linked_belts_with(function(side) return { layers = { [layer[side]] = true } } end)
elseif variant == "not-colliding-with-itself" then
  -- One shared mask (the vanilla belt layers) that does not collide with itself.
  linked_belts_with(function()
    return {
      layers = { floor = true, meltable = true, object = true, transport_belt = true, water_tile = true },
      not_colliding_with_itself = true,
    }
  end)
elseif variant == "tiles-only" then
  -- The vanilla belt layers, colliding with tiles only.
  linked_belts_with(function()
    return {
      layers = { floor = true, meltable = true, object = true, transport_belt = true, water_tile = true },
      colliding_with_tiles_only = true,
    }
  end)
elseif variant == "loader-custom-layers" then
  -- loader-1x1 per side, one custom layer per side.
  local v = {}
  for _, side in ipairs(SIDES) do
    v[#v + 1] = { type = "collision-layer", name = "mb_spike_ld_" .. side }
    local p = table.deepcopy(ld)
    p.name = "mb-spike-var-ld-" .. side
    p.collision_mask = { layers = { ["mb_spike_ld_" .. side] = true } }
    v[#v + 1] = p
  end
  data:extend(v)
end
