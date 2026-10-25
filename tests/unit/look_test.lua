-- Connected look (scripts/look.lua): the neighbourhood masks and their graphics variations, in
-- the order the sprite sheets use (tools/gen_sprites.py).
local look = require("scripts.look")

return {
  forty_seven_masks_in_ascending_order = function()
    local ms = look.masks()
    assert(#ms == 47, "expected 47 masks, got " .. #ms)
    for i = 2, #ms do
      assert(ms[i] > ms[i - 1], "masks not ascending at " .. i)
    end
    assert(ms[1] == 0, "a lone block must be variation 1")
  end,
  corner_bits_need_both_sides = function()
    -- NE (16) without N and E is dropped; with both it stays
    assert(look.canonical(16) == 0, "NE alone must be dropped")
    assert(look.canonical(1 + 16) == 1, "NE with only N must be dropped")
    assert(look.canonical(1 + 2 + 16) == 1 + 2 + 16, "NE with N and E must stay")
    assert(look.variation(255) == 47, "a fully surrounded block is the last variation")
    assert(look.variation(16) == look.variation(0), "a diagonal neighbour alone changes nothing")
  end,
  every_mask_has_a_variation = function()
    for m = 0, 255 do
      local v = look.variation(m)
      assert(v >= 1 and v <= 47, "mask " .. m .. " -> " .. tostring(v))
      assert(look.masks()[v] == look.canonical(m), "mask " .. m .. " maps to the wrong frame")
    end
  end,
}
