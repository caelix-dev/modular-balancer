-- Plain assert, not luassert: luassert's failure formatting crashes on Factorio 2.1.
describe("modular-balancer smoke", function()
  test("nauvis exists", function()
    assert(game.surfaces[1] ~= nil, "surface 1 is missing")
  end)

  -- A rocket lifts 1000 kg (UtilityConstants::default_rocket_lift_weight, unchanged by the mod).
  test("every balancer block tier fits 50 to a rocket", function()
    for _, tier in ipairs({ "basic", "fast", "express", "turbo" }) do
      local item = prototypes.item["mb-balancer-" .. tier]
      assert(item ~= nil, "item mb-balancer-" .. tier .. " is missing")
      local per_rocket = math.floor(1000000 / item.weight)
      assert(per_rocket == 50, "mb-balancer-" .. tier .. ": " .. per_rocket .. " per rocket, expected 50")
    end
  end)
end)
