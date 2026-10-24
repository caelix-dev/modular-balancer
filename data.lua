-- The visible balancer blocks (entity, item, recipe and technology unlock per tier).
require("prototypes.blocks")
-- The hidden network prototypes are created in data-final-fixes.lua (speeds from the final belts).

-- Test harness prototypes, only with factorio-test (never in the product).
---@diagnostic disable-next-line: unnecessary-if
if mods["factorio-test"] then
  require("tests.game.data")
end

if settings.startup["mb-spikes"].value then
  require("spikes.multi_belt.data")
  require("spikes.hidden_surface.data")
end
