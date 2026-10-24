-- Spike S1 (throwaway): several belts per 1x1 block. Loaded only with the `mb-spikes`
-- startup setting. Nothing here is a product prototype.
--
-- Measured (prototype load errors, see docs/feasibility.md F1):
--   * a belt-connectable mask that does not collide with the "transport-belt" prototype is
--     refused ("must collide with entity prototype transport-belt");
--   * two belt-connectable prototypes with disjoint layers are refused ("must collide with
--     entity prototype mb-spike-lb-e");
--   * one shared mask with `not_colliding_with_itself` is refused as well ("mb-spike-lb-e
--     must collide with entity prototype mb-spike-lb-e").
-- So every belt-connectable prototype collides with every other one, itself included, and the
-- interfaces below keep the default belt mask. Runtime stacking is tested in test.lua.

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
-- as the player's belt. Mining it gives the belt item back.
local edge = table.deepcopy(lb)
edge.name = "mb-spike-edge"
edge.structure = nil
edge.allow_side_loading = true
edge.minable = { mining_time = 0.1, result = tier_belt }
edge.placeable_by = { item = tier_belt, count = 1 }
edge.belt_animation_set = data.raw["transport-belt"][tier_belt].belt_animation_set
protos[#protos + 1] = edge

-- Test harness: a loader at the tier speed that feeds from / sinks into an adjacent chest.
local io_loader = table.deepcopy(data.raw["loader-1x1"]["loader-1x1"])
io_loader.name = "mb-spike-io-loader"
io_loader.speed = speed
io_loader.minable = nil
protos[#protos + 1] = io_loader

data:extend(protos)
