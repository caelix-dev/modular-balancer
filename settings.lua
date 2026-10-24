-- `mb-spikes` gates the throwaway research spikes under spikes/. It is off in the product.
-- A developer turns it on locally by creating the git-ignored file spikes/local-enable.lua
-- containing `return true` (fdev test cannot set startup settings). The setting is hidden and
-- forced to that choice, so a value saved earlier in an instance's mod-settings.dat cannot
-- override it either way.
local ok, enabled = pcall(require, "spikes.local-enable")
local dev = ok and enabled == true
data:extend({
  {
    type = "bool-setting",
    name = "mb-spikes",
    setting_type = "startup",
    default_value = dev,
    hidden = true,
    forced_value = dev,
  },
})
