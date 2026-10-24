-- Spike S2 (throwaway): linked belts across surfaces, inserter access to and input into a
-- hidden network, lane balancing. Loaded only with the `mb-spikes` startup setting, after
-- spikes/multi_belt/data.lua (it reuses mb-spike-lb, mb-spike-block and mb-spike-io-loader).
-- Nothing here is a product prototype. Results: docs/feasibility.md F2-F5.

-- Belt speed of the tier the spike measures: turbo with Space Age, else express.
local tier_belt = mods["space-age"] and "turbo-transport-belt" or "express-transport-belt"
local speed = data.raw["transport-belt"][tier_belt].speed

data:extend({ { type = "collision-layer", name = "mb_spike_buffer" } })

local protos = {}

-- The visible block as a proxy container: the vanilla proxy-container (it exposes another
-- entity's inventory) with the F1 block mask, so it can share its tile with one hidden
-- linked belt.
local proxy = table.deepcopy(data.raw["proxy-container"]["proxy-container"])
proxy.name = "mb-spike-proxy"
proxy.collision_mask = { layers = { item = true, player = true, is_object = true } }
proxy.minable = nil
protos[#protos + 1] = proxy

-- The hidden buffer chest a network output feeds (through a loader) and the proxy exposes.
-- One slot, so at most one stack waits in it; own layer, so it collides with nothing else.
local buffer = table.deepcopy(data.raw["container"]["steel-chest"])
buffer.name = "mb-spike-buffer"
buffer.inventory_size = 1
buffer.collision_mask = { layers = { mb_spike_buffer = true } }
buffer.minable = nil
protos[#protos + 1] = buffer

-- F3 with mixed items (fix round 1): the same buffer with two slots, and with two slots that
-- can be filtered per item (LuaInventory::set_filter, like a cargo wagon).
local buffer2 = table.deepcopy(buffer)
buffer2.name = "mb-spike-buffer-2"
buffer2.inventory_size = 2
protos[#protos + 1] = buffer2

local buffer_filtered = table.deepcopy(buffer2)
buffer_filtered.name = "mb-spike-buffer-filtered"
buffer_filtered.inventory_type = "with_filters_and_bar"
protos[#protos + 1] = buffer_filtered

-- Test harness: an assembling machine that needs no power (for the mixed-item deadlock test).
local assembler = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
assembler.name = "mb-spike-assembler"
assembler.energy_source = { type = "void" }
assembler.minable = nil
assembler.next_upgrade = nil
protos[#protos + 1] = assembler

-- Test harness: a counting chest that does not fill up in a long measurement (a steel chest
-- holds 4 800 plates, less than a turbo belt delivers in 80 s).
local sink = table.deepcopy(data.raw["container"]["steel-chest"])
sink.name = "mb-spike-sink"
sink.inventory_size = 500
sink.minable = nil
protos[#protos + 1] = sink

-- Test harness: a bulk inserter that needs no power.
local inserter = table.deepcopy(data.raw["inserter"]["bulk-inserter"])
inserter.name = "mb-spike-inserter"
inserter.energy_source = { type = "void" }
inserter.minable = nil
protos[#protos + 1] = inserter

-- The lane splitter at the measured tier (the vanilla one runs at yellow speed).
local lane_splitter = table.deepcopy(data.raw["lane-splitter"]["lane-splitter"])
lane_splitter.name = "mb-spike-lane-splitter"
lane_splitter.speed = speed
lane_splitter.minable = nil
protos[#protos + 1] = lane_splitter

data:extend(protos)
