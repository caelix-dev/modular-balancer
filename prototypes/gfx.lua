-- Which rendered sprite set the blocks and port hoods use (tools/render/: Blender renders packed
-- by tools/render/pack.py). "hr": 64 px per tile, frames 112 px, scale 0.5 (vanilla 2.x density);
-- "lr": 32 px per tile, frames 56 px, scale 1 (lower-fi). Frames are 1.75 tiles, the tile centred.
local SET = "hr"
local sets = {
  hr = { frame = 112, scale = 0.5 },
  lr = { frame = 56, scale = 1 },
}
local s = sets[SET]
return { dir = "__modular-balancer__/graphics/entity/balancer/" .. SET .. "/", frame = s.frame, scale = s.scale }
