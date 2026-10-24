-- Offline test runner. Run from the repo root:
--   ..\.tools\lua52\lua52.exe tests/unit/run.lua
-- Each tests/unit/*_test.lua returns { [name] = function() ... end }.
package.path = "./?.lua;" .. package.path

local is_windows = package.config:sub(1, 1) == "\\"

local function list_tests()
  local cmd = is_windows and "dir /b tests\\unit\\*_test.lua" or "ls tests/unit/*_test.lua"
  local pipe = assert(io.popen(cmd))
  local files = {}
  for line in pipe:lines() do
    local name = tostring(line):match("([^/\\]+_test%.lua)%s*$")
    if name then
      files[#files + 1] = name
    end
  end
  pipe:close()
  table.sort(files)
  return files
end

local failures, total = 0, 0

for _, file in ipairs(list_tests()) do
  local path = "tests/unit/" .. file
  local loaded, suite = pcall(dofile, path)
  if not loaded or type(suite) ~= "table" then
    failures, total = failures + 1, total + 1
    print("FAIL " .. path .. "::<load>: " .. tostring(suite))
  else
    local names = {}
    for name in pairs(suite) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      total = total + 1
      local ok, err = pcall(suite[name])
      if ok then
        print("ok " .. path .. "::" .. name)
      else
        failures = failures + 1
        print("FAIL " .. path .. "::" .. name .. ": " .. tostring(err))
      end
    end
  end
end

print(string.format("%d tests, %d failures", total, failures))
os.exit(failures == 0 and 0 or 1)
