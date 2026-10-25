local surface = require("scripts.surface")
local builder = require("scripts.builder")
local groups = require("scripts.groups")
local events = require("scripts.events")
local balancer = require("scripts.balancer")
local lifecycle = require("scripts.lifecycle")

-- A mod that changes a belt speed after modular-balancer's data-final-fixes leaves the hidden
-- network of that tier at the old speed; log it (final review M3, Task 2 review M6).
local function check_speeds()
  for _, msg in ipairs(builder.speed_mismatches()) do
    log("modular-balancer: hidden network speed differs from its belt: " .. msg)
  end
end
-- on_init and on_configuration_changed can each be registered only once: later tasks add their
-- work to these handlers (call it from here), they do not register their own.
script.on_init(function()
  groups.init()
  check_speeds()
end)
-- A configuration change: blocks that vanished leave their groups, a removed tier's blocks are
-- downgraded and a lost hidden surface is replaced (scripts/lifecycle.lua), and every group is
-- refreshed at the next tick (ports whose edge or belt prototype vanished, changed speeds).
script.on_configuration_changed(function()
  local ids, gone = groups.on_configuration_changed()
  balancer.mark(ids, gone)
  lifecycle.on_configuration_changed()
  balancer.harden()
  check_speeds()
end)
-- Only re-sets the conditional flush handler (MODDING-RULES §2).
script.on_load(function()
  balancer.on_load()
end)

events.register()

script.on_event(defines.events.on_force_created, function(event)
  surface.on_force_created(event.force)
end)

-- Test code only with the dev gate (settings.lua: factorio-test and the dev marker tests/dev.lua,
-- which release zips leave out, so a player with factorio-test enabled gets none of it).
if settings.startup["mb-dev"].value then
  require("tests.game.remote")
  local suites = { "tests/game/smoke", "tests/game/placement", "tests/game/exactness", "tests/game/rebuild", "tests/game/groups", "tests/game/io", "tests/game/play", "tests/game/lifecycle", "tests/game/lanes", "tests/game/staged" }
  if settings.startup["mb-spikes"].value then
    suites[#suites + 1] = "spikes/multi_belt/test"
    suites[#suites + 1] = "spikes/hidden_surface/test"
    require("spikes.hidden_surface.save_load")
  end
  require("__factorio-test__/init")(suites, {})
end
