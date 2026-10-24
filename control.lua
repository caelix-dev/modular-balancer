local surface = require("scripts.surface")

script.on_event(defines.events.on_force_created, function(event)
  surface.on_force_created(event.force)
end)

---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["factorio-test"] then
  require("tests.game.remote")
  local suites = { "tests/game/smoke", "tests/game/placement", "tests/game/exactness" }
  if settings.startup["mb-spikes"].value then
    suites[#suites + 1] = "spikes/multi_belt/test"
    suites[#suites + 1] = "spikes/hidden_surface/test"
    require("spikes.hidden_surface.save_load")
  end
  require("__factorio-test__/init")(suites, {})
end
