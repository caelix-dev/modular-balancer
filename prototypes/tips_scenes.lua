-- The tips and tricks simulations (prototypes/tips.lua), pure data: also loaded by the dev-gated
-- test remote to run the same code on a test server. The scenes are built by a
-- shared helper (prepended to every scene's init, since simulation code runs as a console command
-- and cannot `require`; it leaves its update function in a console global that the per-tick update
-- calls): basic (yellow) belts, blocks built from ghosts with
-- the same tags a blueprint carries (mb_lanes, mb_recirc, mb_filter), item sources that keep a
-- belt full, and sinks that take everything and show what each output lane carries per second.

local HELPER = [[
local s = game.surfaces[1]
storage.mbsim = storage.mbsim or { src = {}, snk = {} }
local sim = storage.mbsim
local E = defines.direction.east
local BELT = "transport-belt"
local function at(x, y) return { x + 0.5, y + 0.5 } end
local function belts(x0, x1, y)
  for x = x0, x1 do
    s.create_entity{ name = BELT, position = at(x, y), direction = E, force = "player", raise_built = true }
  end
end
local function block(x, y, tags)
  local g = s.create_entity{ name = "entity-ghost", inner_name = "mb-balancer-basic", position = at(x, y), force = "player", tags = tags }
  g.revive{ raise_revive = true }
end
local function column(x, y0, y1, tags)
  for y = y0, y1 do block(x, y, tags) end
end
local function text(x, y, t, scale, color, align)
  return rendering.draw_text{ text = t, surface = s, target = { x, y }, color = color or { 1, 1, 1 }, scale = scale or 1,
    alignment = align or "left", vertical_alignment = "middle", use_rich_text = true }
end
-- keeps the first belt of a line full; lanes: {1} left only, {1, 2} both; each lane takes the
-- items in turn
local function source(x, y, items, lanes, label)
  sim.src[#sim.src + 1] = { e = s.find_entity(BELT, at(x, y)), items = items, lanes = lanes or { 1, 2 }, k = { 0, 0 }, n = 0, r = 0,
    t = label and text(x - 0.6, y + 0.5, "", 0.8, nil, "right") or nil }
end
-- takes everything from the last belt of a line and shows each lane's items per second
local function sink(x, y)
  sim.snk[#sim.snk + 1] = { e = s.find_entity(BELT, at(x, y)), n = { {}, {} }, r = { {}, {} },
    t = { text(x + 1.2, y + 0.22, "", 0.75), text(x + 1.2, y + 0.78, "", 0.75) } }
end
local function caption(x, y, key)
  text(x, y, { key }, 1.2, { 1, 0.85, 0.4 }, "left")
end
local function camera(x, y, zoom, alt)
  if game.simulation then
    game.simulation.camera_position = { x, y }
    game.simulation.camera_zoom = zoom or 1
    game.simulation.camera_alt_info = alt or false
  end
end
-- what passed in the last WINDOW seconds, per second (a ring of one-second counts)
local WINDOW = 10
local function push(ring, counts)
  ring[#ring + 1] = counts
  if #ring > WINDOW then table.remove(ring, 1) end
  local sum = {}
  for _, c in pairs(ring) do for name, v in pairs(c) do sum[name] = (sum[name] or 0) + v end end
  for name, v in pairs(sum) do sum[name] = v / #ring end
  return sum
end
local function update()
  sim.t = (sim.t or 0) + 1
  for _, src in pairs(sim.src) do
    if src.e and src.e.valid then
      for _, i in pairs(src.lanes) do
        local l = src.e.get_transport_line(i)
        if l.can_insert_at_back() then
          src.k[i] = src.k[i] + 1
          l.insert_at_back({ name = src.items[(src.k[i] - 1) % #src.items + 1], count = 1 })
          src.n = src.n + 1
        end
      end
    end
  end
  for _, k in pairs(sim.snk) do
    if k.e and k.e.valid then
      for i = 1, 2 do
        local l = k.e.get_transport_line(i)
        for _, c in pairs(l.get_contents()) do k.n[i][c.name] = (k.n[i][c.name] or 0) + c.count end
        l.clear()
      end
    end
  end
  if sim.t % 60 ~= 0 then return end
  for _, src in pairs(sim.src) do
    src.ring = src.ring or {}
    local r = push(src.ring, { n = src.n }).n or 0
    src.n = 0
    if src.t then src.t.text = string.format("%.1f/s", r) end
  end
  for _, k in pairs(sim.snk) do
    k.ring = k.ring or { {}, {} }
    for i = 1, 2 do
      local rate = push(k.ring[i], k.n[i])
      k.n[i] = {}
      local parts = {}
      for name, v in pairs(rate) do
        if v >= 0.05 then parts[#parts + 1] = "[item=" .. name .. "]" .. string.format("%.1f", v) end
      end
      table.sort(parts)
      k.t[i].text = #parts > 0 and table.concat(parts, "  ") or "0"
    end
  end
end
-- a global of the console environment, so the per-tick update calls it instead of compiling this
-- helper again every tick (compiling it took about two thirds of the update's time)
mbsim_update = update
]]

-- Every scene: inputs come from the west into a column of blocks at x = 0, outputs leave to the
-- east. Lines are 7 tiles long on each side. `warmup`: ticks the simulation runs before it is
-- shown (init_update_count; the game pauses for them when a tip opens), each the measured time for
-- the scene's new networks to fill and its 10 s rates to settle, plus about 300 ticks. Filling the
-- hidden belts by script was tried and is slower: a network holds more items packed than in its
-- steady state, and draining the surplus through the recirculation takes longer than filling.
local SCENES = {
  {
    name = "basic",
    warmup = 3000,
    zoom = 1.1,
    camera = { 1, 0.5 },
    code = [[
column(0, -1, 1)
for _, y in pairs({ -1, 0 }) do belts(-7, -1, y); source(-7, y, { "iron-plate" }, nil, true) end
for _, y in pairs({ -1, 0, 1 }) do belts(1, 7, y); sink(7, y) end
]],
  },
  {
    name = "lanes",
    warmup = 1500,
    zoom = 1,
    camera = { 1, 0 },
    code = [[
caption(-7, -5.2, "mb-tips.lanes-off")
column(0, -4, -3)
belts(-7, -1, -4); source(-7, -4, { "iron-plate" }, { 1 }, true)
for _, y in pairs({ -4, -3 }) do belts(1, 7, y); sink(7, y) end
caption(-7, 0.8, "mb-tips.lanes-on")
column(0, 2, 3, { mb_lanes = true })
belts(-7, -1, 2); source(-7, 2, { "iron-plate" }, { 1 }, true)
for _, y in pairs({ 2, 3 }) do belts(1, 7, y); sink(7, y) end
]],
  },
  {
    name = "recirc",
    warmup = 2700,
    zoom = 0.85,
    camera = { 1, 0 },
    code = [[
local function rig(y0, recirc)
  column(0, y0, y0 + 3, { mb_lanes = false, mb_recirc = recirc })
  belts(-7, -1, y0); source(-7, y0, { "iron-plate" }, nil, true)
  for i = 0, 3 do
    belts(1, i == 1 and 4 or 7, y0 + i)
    if i == 1 then text(5.2, y0 + i + 0.5, { "mb-tips.blocked" }, 0.75, { 1, 0.45, 0.4 }) else sink(7, y0 + i) end
  end
end
caption(-7, -6.2, "mb-tips.recirc-off")
rig(-5, false)
caption(-7, 0.8, "mb-tips.recirc-on")
rig(2, true)
]],
  },
  {
    name = "filters",
    warmup = 1500,
    zoom = 1.1,
    camera = { 1, 0.5 },
    alt = true,
    code = [[
block(0, -1, { mb_filter = { use = true, items = { "copper-plate" } } })
block(0, 0); block(0, 1)
belts(-7, -1, 0); source(-7, 0, { "iron-plate", "copper-plate" }, nil, true)
for _, y in pairs({ -1, 0, 1 }) do belts(1, 7, y); sink(7, y) end
]],
  },
  {
    name = "lane-filters",
    warmup = 1800,
    zoom = 1.1,
    camera = { 1, 0.5 },
    alt = true,
    code = [[
block(0, 0, { mb_filter = { use = true, lanes = true, items = { "iron-plate", "copper-plate" } } })
belts(-7, -1, 0); source(-7, 0, { "iron-plate", "copper-plate" }, nil, true)
belts(1, 7, 0); sink(7, 0)
]],
  },
  {
    name = "half-belt",
    warmup = 1800,
    zoom = 1,
    camera = { 1, 0 },
    alt = true,
    code = [[
caption(-7, -4.2, "mb-tips.half-off")
block(0, -3)
belts(-7, -1, -3); source(-7, -3, { "iron-plate" }, nil, true)
belts(1, 7, -3); sink(7, -3)
caption(-7, 0.8, "mb-tips.half-on")
block(0, 2, { mb_filter = { use = true, lanes = true, items = { "deconstruction-planner" } } })
belts(-7, -1, 2); source(-7, 2, { "iron-plate" }, nil, true)
belts(1, 7, 2); sink(7, 2)
]],
  },
}

-- init (camera and scene) and update code of scene `sc`, as the simulation runs them
local function code(sc)
  return HELPER .. string.format("camera(%s, %s, %s, %s)\n", sc.camera[1], sc.camera[2], sc.zoom, tostring(sc.alt or false)) .. sc.code,
    "if mbsim_update then mbsim_update() end"
end

return { SCENES = SCENES, code = code }
