-- Two hidden, forced startup settings gate the development code (final review M4). Neither a
-- player nor a value saved earlier in an instance's mod-settings.dat can change them.
--
-- `mb-dev` gates the test code: the harness prototypes (tests/game/data.lua), the `mb-test`
-- remote interface (tests/game/remote.lua) and the FactorioTest suites. It is on only when the
-- factorio-test mod is enabled and the dev marker tests/dev.lua exists. `tests/` is
-- export-ignored, so a release zip built with `git archive` never turns it on.
--
-- `mb-spikes` gates the throwaway research spikes under spikes/ (their prototypes and test
-- suites). It needs `mb-dev` and, in addition, the git-ignored file spikes/local-enable.lua
-- (fdev test cannot set startup settings). That file returns `true`, or a table
-- `{ variant = "<name>" }` that also selects a prototype variant of spikes/multi_belt/data.lua
-- (used by spikes/multi_belt/repro-load-errors.sh to reproduce the prototype-stage errors).
-- spikes/ is export-ignored too.
local has_test_mod = mods["factorio-test"] ~= nil
local marker_ok, marker = pcall(require, "tests.dev")
local dev_tests = has_test_mod and marker_ok and marker == true
local ok, enabled = pcall(require, "spikes.local-enable")
local dev = dev_tests and ok and enabled ~= nil and enabled ~= false
local variant = dev and type(enabled) == "table" and enabled.variant or "none"
data:extend({
  {
    type = "bool-setting",
    name = "mb-dev",
    setting_type = "startup",
    default_value = dev_tests,
    hidden = true,
    forced_value = dev_tests,
  },
  {
    type = "bool-setting",
    name = "mb-spikes",
    setting_type = "startup",
    default_value = dev,
    hidden = true,
    forced_value = dev,
  },
  {
    type = "string-setting",
    name = "mb-spikes-variant",
    setting_type = "startup",
    default_value = variant,
    allowed_values = { variant },
    hidden = true,
    forced_value = variant,
  },
})
