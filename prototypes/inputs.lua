-- Linked custom inputs for the balancer settings GUI (scripts/gui.lua). A balancer block is a
-- simple-entity-with-owner, which has no GUI of its own, so the mod listens to the game's own
-- controls: open-gui (click a block), copy-entity-settings and paste-entity-settings. Linked
-- inputs do not appear in the controls settings and consume nothing, so the game still does
-- what it would do for any other entity.
data:extend({
  { type = "custom-input", name = "mb-open-gui", key_sequence = "", linked_game_control = "open-gui" },
  { type = "custom-input", name = "mb-copy-settings", key_sequence = "", linked_game_control = "copy-entity-settings" },
  { type = "custom-input", name = "mb-paste-settings", key_sequence = "", linked_game_control = "paste-entity-settings" },
})
