-- Test-only mod (tests/game/placement.lua tier_speed_follows_final_prototypes, run as an MCP
-- check, see docs/feasibility.md): changes the express belt speed in data-final-fixes. Its name
-- sorts before "modular-balancer", so with the same dependency depth this runs before
-- modular-balancer's data-final-fixes, which must then build the hidden express entities at the
-- new speed. 26/256 tiles per tick instead of 24/256 (48.75 items/s instead of 45).
data.raw["transport-belt"]["express-transport-belt"].speed = 26 / 256
