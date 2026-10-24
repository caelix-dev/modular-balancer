---@diagnostic disable-next-line: unnecessary-if
if script.active_mods["factorio-test"] then
  require("__factorio-test__/init")({ "tests/game/smoke" }, {})
end
