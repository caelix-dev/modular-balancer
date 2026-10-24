-- Plain assert, not luassert: luassert's failure formatting crashes on Factorio 2.1.
describe("modular-balancer smoke", function()
  test("nauvis exists", function()
    assert(game.surfaces[1] ~= nil, "surface 1 is missing")
  end)
end)
