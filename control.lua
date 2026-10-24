---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["factorio-test"] then
  local suites = { "tests/game/smoke" }
  if settings.startup["mb-spikes"].value then
    suites[#suites + 1] = "spikes/multi_belt/test"
    suites[#suites + 1] = "spikes/hidden_surface/test"
    require("spikes.hidden_surface.save_load")
  end
  require("__factorio-test__/init")(suites, {})
end
