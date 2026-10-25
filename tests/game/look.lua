-- Connected look (scripts/look.lua, set by scripts/balancer.lua on every group refresh): each
-- block's graphics variation follows its group's tiles, through builds and removals.
-- Plain assert, not luassert.
local H = require("tests.game.harness")
local balancer = require("scripts.balancer")
local look = require("scripts.look")

local function expected(blocks, b)
  local m = 0
  for _, o in ipairs(look.OFFSETS) do
    local other = blocks[(b.position.x + o[1]) .. "," .. (b.position.y + o[2])]
    if other and other.valid then
      m = m + o[3]
    end
  end
  return look.variation(m)
end

local function check(blocks, what)
  for key, b in pairs(blocks) do
    if b.valid then
      local want = expected(blocks, b)
      assert(b.graphics_variation == want, what .. ": block at " .. key .. " has variation "
        .. tostring(b.graphics_variation) .. ", expected " .. want)
    end
  end
end

describe("look", function()
  ---@type BoundingBox?
  local last_box
  after_each(function()
    if last_box then
      H.clear_blocks(last_box)
      last_box = nil
    end
  end)

  test("l_shape_variations_follow_the_group", function()
    local o, box = H.area(10, 10)
    last_box = box
    ---@type table<string, LuaEntity?>
    local blocks = {}
    local function put(dx, dy, tier)
      local b = H.block(o, dx, dy, tier or "basic")
      blocks[b.position.x .. "," .. b.position.y] = b
      return b
    end
    local corner
    for dx = 0, 4 do
      corner = put(dx, 0)
    end
    local bent = put(4, 1)
    local fast = put(3, 1, "fast") -- another tier never joins: it stays a lone block, and the L ignores it
    balancer.flush()
    ---@type table<string, LuaEntity?>
    local basic = {}
    for k, b in pairs(blocks) do
      if b.name == "mb-balancer-basic" then
        basic[k] = b
      end
    end
    check(basic, "L-shape")
    assert(corner.graphics_variation ~= 1, "the corner block reads as joined")
    assert(fast.graphics_variation == 1, "a different tier must not join: " .. tostring(fast.graphics_variation))
    -- removing the bent block turns the row's end back into an end
    bent.destroy({ raise_destroy = true })
    balancer.flush()
    check(basic, "after removal")
  end)
end)
