-- Per-block item filters. Pure Lua (no game API), so tests/unit can check it offline.
--
-- A block's filter applies to the outputs of that block (its belt outputs, its shared tiles and
-- its inserter port). The settings of a group (scripts/gui.lua) are shared by its blocks; a
-- filter belongs to one block. The routing is done by the group's hidden network
-- (scripts/network.lua, filtered networks), never by script.
--
-- Record (stored on the block, scripts/groups.lua, and as the blueprint tag mb_filter):
--   { items = { s1, s2, s3, s4, s5 }, use = boolean, exclude = boolean, lanes = boolean }
-- Slots hold item names, "" for an empty slot (tags keep no holes in arrays). The default (every
-- slot empty, both flags off) is stored as nil.
--   use       "Use filters" (as on an inserter): off, the record is kept but filters nothing.
--   items     whitelist: the block's outputs take only these items, and these items go only to
--             blocks that list them (exclusive, like a vanilla filter splitter).
--   exclude   blacklist: the block's outputs take everything except these items (and except the
--             items another block's whitelist claims).
--   lanes     per lane: slot 1 goes on the left lane of every output of the block, slot 2 on the
--             right lane (a whitelist per lane). A lane whose slot is empty takes everything else,
--             as an output without a filter would. Slots 3 to 5 and `exclude` are kept
--             but do nothing while it is on (the GUI locks them, and the group's balance-lanes
--             checkbox in this block's window).
-- Items are matched by name, any quality (a splitter filter without a quality, measured).
local filters = {}

filters.SLOTS = 5

-- A clean copy of record `f` (from storage, a tag or the GUI), or nil for the default or garbage.
---@param f any
---@return { items: string[], use: boolean, exclude: boolean, lanes: boolean }?
function filters.normalize(f)
  if type(f) ~= "table" then
    return nil
  end
  local items, any = {}, false
  local src = type(f.items) == "table" and f.items or {}
  for i = 1, filters.SLOTS do
    local v = src[i]
    if v == nil then
      v = src[tostring(i)]
    end
    if type(v) == "string" and v ~= "" then
      items[i] = v
      any = true
    else
      items[i] = ""
    end
  end
  local exclude, lanes = f.exclude == true, f.lanes == true
  -- a record from before "Use filters" existed (no `use`) was in use
  local use = f.use == true or (f.use == nil and (any or exclude or lanes))
  if not (any or use or exclude or lanes) then
    return nil
  end
  return { items = items, use = use, exclude = exclude, lanes = lanes }
end

-- True when two records (normalized or not) are the same.
function filters.same(a, b)
  a, b = filters.normalize(a), filters.normalize(b)
  if a == nil or b == nil then
    return a == b
  end
  if a.use ~= b.use or a.exclude ~= b.exclude or a.lanes ~= b.lanes then
    return false
  end
  for i = 1, filters.SLOTS do
    if a.items[i] ~= b.items[i] then
      return false
    end
  end
  return true
end

---@class mb.FilterSpec
---@field lanes boolean? per lane: `left` on the left lane, `right` on the right lane
---@field left string?
---@field right string?
---@field exclude boolean? blacklist of `items` (else whitelist)
---@field items string[]? sorted, distinct (not with lanes)

-- What record `f` does, for the network: nil when it does nothing ("Use filters" off, or no item
-- that `valid` accepts: every slot empty, or only items that no longer exist), else a spec. `valid` (item name ->
-- boolean, default accepts all) drops items of removed mods.
---@param f any
---@param valid (fun(name: string): boolean)?
---@return mb.FilterSpec?
function filters.effective(f, valid)
  f = filters.normalize(f)
  if not (f and f.use) then
    return nil
  end
  local function ok(name)
    return name ~= "" and (valid == nil or valid(name))
  end
  if f.lanes then
    local l = ok(f.items[1]) and f.items[1] or nil
    local r = ok(f.items[2]) and f.items[2] or nil
    if not (l or r) then
      return nil
    end
    return { lanes = true, left = l, right = r }
  end
  local set, list = {}, {}
  for i = 1, filters.SLOTS do
    local v = f.items[i]
    if ok(v) and not set[v] then
      set[v] = true
      list[#list + 1] = v
    end
  end
  if #list == 0 then
    return nil
  end
  table.sort(list)
  return { exclude = f.exclude or nil, items = list }
end

-- A string that differs whenever the specs of outputs 1..m differ (part of a rebuild's shape).
---@param specs (mb.FilterSpec|false)[]?
---@param m integer
---@return string
function filters.signature(specs, m)
  if not specs then
    return ""
  end
  local parts, any = {}, false
  for j = 1, m do
    local s = specs[j]
    if not s then
      parts[j] = "-"
    elseif s.lanes then
      parts[j] = "L:" .. (s.left or "") .. "|" .. (s.right or "")
      any = true
    else
      parts[j] = (s.exclude and "B:" or "W:") .. table.concat(s.items or {}, ",")
      any = true
    end
  end
  return any and table.concat(parts, ";") or ""
end

-- True when any of `specs` filters.
---@param specs (mb.FilterSpec|false)[]?
---@return boolean
function filters.any(specs)
  if not specs then
    return false
  end
  for _, s in pairs(specs) do
    if s then
      return true
    end
  end
  return false
end

return filters
