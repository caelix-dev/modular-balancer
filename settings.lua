-- `mb-spikes` gates the throwaway research spikes under spikes/ (their prototypes and test
-- suites). It is off in the product. Both settings below are hidden and forced, so neither a
-- player nor a value saved earlier in an instance's mod-settings.dat can change them.
--
-- A developer turns the spikes on by creating the git-ignored file spikes/local-enable.lua
-- (fdev test cannot set startup settings). It returns `true`, or a table
-- `{ variant = "<name>" }` that also selects a prototype variant of spikes/multi_belt/data.lua
-- (used by spikes/multi_belt/repro-load-errors.sh to reproduce the prototype-stage errors).
-- The file only counts while the factorio-test mod is enabled, so a release zip that carried
-- it by mistake still loads without spikes for players (also build releases with
-- `git archive`, see CLAUDE.md).
local ok, enabled = pcall(require, "spikes.local-enable")
local dev = ok and enabled ~= nil and enabled ~= false and mods["factorio-test"] ~= nil
local variant = dev and type(enabled) == "table" and enabled.variant or "none"
data:extend({
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
