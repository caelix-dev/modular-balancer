-- Tips and tricks: a category with one entry per use of the balancer, each with a simulation of a
-- real balancer (the mod's runtime scripts run inside it, `mods`). Scenes in prototypes/tips_scenes.lua.
local T = require("prototypes.tips_scenes")

data:extend({
  { type = "tips-and-tricks-item-category", name = "modular-balancer", order = "z-mb" },
  {
    type = "tips-and-tricks-item",
    name = "mb-tips",
    category = "modular-balancer",
    order = "a",
    is_title = true,
    starting_status = "unlocked",
    tag = "[entity=mb-balancer-basic]",
  },
})

for i, sc in ipairs(T.SCENES) do
  local init, update = T.code(sc)
  data:extend({
    {
      type = "tips-and-tricks-item",
      name = "mb-tips-" .. sc.name,
      category = "modular-balancer",
      order = string.format("b%02d", i),
      indent = 1,
      starting_status = "unlocked",
      simulation = {
        mods = { "modular-balancer" },
        checkboard = true,
        init_update_count = sc.warmup,
        init = init,
        update = update,
      },
    },
  })
end

