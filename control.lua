local surface = require("scripts.surface")
local builder = require("scripts.builder")
local groups = require("scripts.groups")
local events = require("scripts.events")
local balancer = require("scripts.balancer")

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
script.on_configuration_changed(function()
  local ids, gone = groups.on_configuration_changed()
  balancer.mark(ids, gone)
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

---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["factorio-test"] then
  require("tests.game.remote")
  local suites = { "tests/game/smoke", "tests/game/placement", "tests/game/exactness", "tests/game/rebuild", "tests/game/groups", "tests/game/io", "tests/game/play" }
  if settings.startup["mb-spikes"].value then
    suites[#suites + 1] = "spikes/multi_belt/test"
    suites[#suites + 1] = "spikes/hidden_surface/test"
    require("spikes.hidden_surface.save_load")
  end
  require("__factorio-test__/init")(suites, {})
end
