local function add(a, b)
  return a + b
end

return {
  arithmetic_works = function()
    assert(add(1, 1) == 2, "1 + 1 should be 2")
  end,
}
