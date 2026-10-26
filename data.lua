-- The visible balancer blocks (entity, item, recipe and technology unlock per tier).
require("prototypes.blocks")
-- Linked custom inputs of the balancer settings GUI.
require("prototypes.inputs")
-- The hidden network prototypes are created in data-final-fixes.lua (speeds from the final belts).

-- Test harness prototypes, only with the dev gate (settings.lua: factorio-test and the dev
-- marker tests/dev.lua, which release zips leave out).
if settings.startup["mb-dev"].value then
  require("tests.game.data")
end

if settings.startup["mb-spikes"].value then
  require("spikes.multi_belt.data")
  require("spikes.hidden_surface.data")
end
