-- Hidden entities of the balancing network, one set per belt tier. They live only on the hidden
-- surface (scripts/surface.lua) and are placed by scripts/builder.lua:
--   mb-hidden-splitter-<tier>       copy of the vanilla splitter of that tier; also the priority
--                                   splitter (splitter_output_priority is set at runtime)
--   mb-hidden-linked-belt-<tier>    copy of `linked-belt`; every network edge is one pair of these
--                                   (docs/feasibility.md F1, F2)
--   mb-hidden-lane-splitter-<tier>  copy of the vanilla `lane-splitter` (yellow speed in base),
--                                   for the balance-lanes option (F5)
--   mb-hidden-loader-<tier>         loader-1x1 that drains the network's buffer chest
--   mb-hidden-never                 an item that never exists: the splitter filter that closes a
--                                   splitter's dead-end output (scripts/builder.lua). It is
--                                   hidden and has no recipe; only a cheat (a console insert, an
--                                   editor filter) can create it. Such an item takes the closed
--                                   side and jams that splitter lane; builder.contents and
--                                   builder.drain drop it, so the next rebuild clears the jam
--   mb-hidden-buffer                the buffer chest (one per network) that holds what a rebuild
--                                   could not put back on the belts; its size is set per network
--                                   at runtime with set_inventory_size_override
-- On the player's surfaces, scripts/io.lua places:
--   mb-hidden-linked-belt-<tier>    also the block-tile interface and the inserter belt port (F1,
--                                   F3), on a block's own tile under the block
--   mb-edge-in-<belt>, mb-edge-out-<belt>
--                                   edges (F1): one input and one output linked belt per
--                                   transport-belt prototype (modded belts included), at that
--                                   belt's speed, with its belt animation, mining and placing as
--                                   that belt. The last tile of a player belt that points into a
--                                   block (input) or leaves it (output) is swapped for one. Input
--                                   edges allow side loading like the belt they replace; output
--                                   edges do not. They look like the belt (no hatch; the half
--                                   tile a linked belt leaves blank is drawn by scripts/io.lua,
--                                   see below). They have a fast-replace group of their own
--                                   (below), so a belt dragged across or against one goes under
--                                   it; a line dragged along it in its direction replaces it
--                                   (scripts/lifecycle.lua, on_pre_build) and the balancer swaps
--                                   the new belt again. Hidden, so no planner lists them
-- Tiers: basic, fast, express and turbo (see TIERS).
--
-- Required from data-final-fixes.lua, so every speed is read from the final belt prototype: a
-- mod that changes a belt's speed in data-updates or in an earlier data-final-fixes also
-- changes the hidden entities of that tier.

---@type { name: string, belt: string, splitter: string, speed: number? }[]
local TIERS = {
  { name = "basic", belt = "transport-belt", splitter = "splitter" },
  { name = "fast", belt = "fast-transport-belt", splitter = "fast-splitter" },
  { name = "express", belt = "express-transport-belt", splitter = "express-splitter" },
}
-- The turbo tier exists even without Space Age, so a save with turbo balancers keeps their hidden
-- networks (and the items on them) when Space Age is removed: the game would otherwise delete
-- every entity of a removed prototype with its items. Without the turbo belt it copies the
-- express entities at TURBO_SPEED, and control.lua downgrades the turbo blocks to express
-- (scripts/lifecycle.lua).
local TURBO_SPEED = 0.125 -- the Space Age turbo belt (60 items/s)
---@diagnostic disable-next-line: unnecessary-if
if data.raw["transport-belt"]["turbo-transport-belt"] then
  TIERS[#TIERS + 1] = { name = "turbo", belt = "turbo-transport-belt", splitter = "turbo-splitter" }
else
  TIERS[#TIERS + 1] = { name = "turbo", belt = "express-transport-belt", splitter = "express-splitter", speed = TURBO_SPEED }
end

-- `hidden` is a PrototypeBase property in 2.1, not an entity flag.
local FLAGS = {
  "not-blueprintable",
  "not-deconstructable",
  "not-on-map",
  "no-copy-paste",
  "not-selectable-in-game",
  "not-upgradable",
}

local function hide(p, name)
  p.name = name
  p.flags = table.deepcopy(FLAGS)
  p.hidden = true
  p.hidden_in_factoriopedia = true
  p.minable = nil
  p.placeable_by = nil
  p.next_upgrade = nil
  p.fast_replaceable_group = nil
  p.allow_copy_paste = false
  return p
end

local function raw(kind, name)
  local p = data.raw[kind] and data.raw[kind][name]
  if not p then
    error("modular-balancer: prototype " .. kind .. "/" .. name .. " is missing")
  end
  return p
end

local protos = {}
for _, tier in ipairs(TIERS) do
  local speed = tier.speed or raw("transport-belt", tier.belt).speed

  local sp = hide(table.deepcopy(raw("splitter", tier.splitter)), "mb-hidden-splitter-" .. tier.name)
  sp.speed = speed
  protos[#protos + 1] = sp

  local lb = hide(table.deepcopy(raw("linked-belt", "linked-belt")), "mb-hidden-linked-belt-" .. tier.name)
  lb.speed = speed
  lb.allow_side_loading = false
  lb.allow_clone_connection = false
  lb.allow_blueprint_connection = false
  protos[#protos + 1] = lb

  local ls = hide(table.deepcopy(raw("lane-splitter", "lane-splitter")), "mb-hidden-lane-splitter-" .. tier.name)
  ls.speed = speed
  protos[#protos + 1] = ls

  local loader = hide(table.deepcopy(raw("loader-1x1", "loader-1x1")), "mb-hidden-loader-" .. tier.name)
  loader.speed = speed
  protos[#protos + 1] = loader
end

local buffer = hide(table.deepcopy(raw("container", "steel-chest")), "mb-hidden-buffer")
-- A loader only takes from a container with "player-creation" (measured: a steel chest without
-- it, or with only "placeable-neutral", gets no loader_container).
buffer.flags[#buffer.flags + 1] = "player-creation"
buffer.inventory_size = 1
buffer.quality_affects_inventory_size = false
protos[#protos + 1] = buffer

local never = table.deepcopy(raw("item", "iron-plate"))
never.name = "mb-hidden-never"
never.hidden = true
never.hidden_in_factoriopedia = true
never.place_result = nil
never.fuel_value = nil
never.fuel_categories = nil
never.spoil_result = nil
never.spoil_ticks = nil
never.subgroup = nil
never.order = "z"
protos[#protos + 1] = never

-- The port hood an edge draws (tools/render/, sprite set from prototypes/gfx.lua): sheets of 6 frames, the hood on the N, E,
-- S, W, N, E side of the tile. An input edge points at its block (hood on the side it faces:
-- frames 1-4 for north, east, south, west), an output edge away from it (frames 3-6). Belts other
-- than the four vanilla tiers get the basic colours. The roof chevrons point the way the items go:
-- hood-<colour>-in.png toward the block, hood-<colour>-out.png away from it.
local HOOD_COLOURS = {
  ["transport-belt"] = "basic",
  ["fast-transport-belt"] = "fast",
  ["express-transport-belt"] = "express",
  ["turbo-transport-belt"] = "turbo",
}
local gfx = require("prototypes.gfx")
local function edge_hood(belt_name, role)
  local colour = HOOD_COLOURS[belt_name] or "basic"
  local function way(first)
    local function sheet(file, shadow)
      return {
        filename = gfx.dir .. file,
        priority = "high",
        width = gfx.frame,
        height = gfx.frame,
        x = (first - 1) * gfx.frame,
        frames = 4,
        scale = gfx.scale,
        draw_as_shadow = shadow or nil,
      }
    end
    return { sheets = { sheet("hood-" .. colour .. "-" .. role .. ".png"), sheet("hood-shadow.png", true) } }
  end
  local hood = way(role == "in" and 1 or 3)
  return {
    direction_in = hood,
    direction_out = hood,
    direction_in_side_loading = hood,
    direction_out_side_loading = hood,
  }
end

-- Edges, one input and one output per transport belt (docs/feasibility.md F1).
local base_edge = raw("linked-belt", "linked-belt")
for _, belt in pairs(data.raw["transport-belt"]) do
  for _, role in ipairs({ "in", "out" }) do
    local e = table.deepcopy(base_edge)
    e.name = "mb-edge-" .. role .. "-" .. belt.name
    e.localised_name = belt.localised_name and table.deepcopy(belt.localised_name) or { "entity-name." .. belt.name }
    e.localised_description = nil
    e.icons = belt.icons and table.deepcopy(belt.icons) or { { icon = belt.icon, icon_size = belt.icon_size } }
    e.icon = nil
    e.icon_size = nil
    e.speed = belt.speed
    e.belt_animation_set = table.deepcopy(belt.belt_animation_set) or e.belt_animation_set
    e.allow_side_loading = role == "in"
    e.allow_clone_connection = false
    e.allow_blueprint_connection = false
    e.minable = belt.minable and table.deepcopy(belt.minable) or nil
    local item = belt.minable and belt.minable.result
    e.placeable_by = item and { item = item, count = 1 } or nil
    e.max_health = belt.max_health
    e.resistances = table.deepcopy(belt.resistances)
    -- `hidden` (below) keeps edges out of the planners' lists and makes them invalid upgrade
    -- sources (order_upgrade on an edge is refused); scripts/lifecycle.lua follows the planner
    -- through the edge's neighbours instead, and redirects any order whose target is an edge
    e.next_upgrade = nil
    -- the belt's look: the belt's animation set, sounds, corpse and explosion; selected like
    -- the belt. Its structure is the block's port hood: a cowling over the half tile next to the block, where items go into or
    -- come out of the link, with the belt's mouth at its far end (graphics/entity/balancer/, rendered by tools/render/).
    e.structure = edge_hood(belt.name, role)
    e.structure_render_layer = "object"
    e.animation_speed_coefficient = belt.animation_speed_coefficient
    e.corpse = belt.corpse
    e.dying_explosion = belt.dying_explosion
    e.working_sound = table.deepcopy(belt.working_sound)
    e.open_sound = table.deepcopy(belt.open_sound)
    e.close_sound = table.deepcopy(belt.close_sound)
    e.collision_box = table.deepcopy(belt.collision_box) or e.collision_box
    e.selection_box = table.deepcopy(belt.selection_box) or e.selection_box
    e.collision_mask = table.deepcopy(belt.collision_mask)
    e.selection_priority = belt.selection_priority
    -- no fast-replace group (the game gives it one of its own): to a belt being built an edge is
    -- an obstacle, so smart belt building drags a line under it (as under a perpendicular plain
    -- belt) instead of replacing it and merging two lines (user bug report 2026-10-30). A line
    -- dragged along it in its direction still replaces it (scripts/lifecycle.lua, on_pre_build).
    e.fast_replaceable_group = nil
    e.hidden = true
    e.hidden_in_factoriopedia = true
    protos[#protos + 1] = e
  end
end

-- The other half of an edge tile. A linked belt draws the belt animation only on the half of its
-- tile away from its link (like an underground belt; measured: an empty `structure` leaves the
-- half toward the block blank, and the starting/ending indices change nothing). scripts/io.lua
-- therefore draws, under each edge (render layer "floor", below the edge's own half belt and its
-- items), the straight belt animation of the edge's belt and direction: one animation prototype
-- `mb-edge-belt-<belt>-<direction>` per belt and direction, cut from the belt's animation sheet
-- (one row per direction, one column per frame). Only single-file sheets (`filename`, no
-- `layers`, `filenames` or `stripes`) are cut; a belt with another layout gets no animations and
-- its edges keep the half belt.
local DEFAULT_INDEX = { east = 1, west = 2, north = 3, south = 4 } -- TransportBeltAnimationSet defaults
for _, belt in pairs(data.raw["transport-belt"]) do
  local set = belt.belt_animation_set
  local a = set and set.animation_set
  if set and a and a.filename and not (a.layers or a.filenames or a.stripes) then
    local size = a.size
    local w = a.width or (type(size) == "table" and size[1]) or size
    local h = a.height or (type(size) == "table" and size[2]) or size
    local frames = a.frame_count or 1
    local ll = a.line_length
    if type(w) == "number" and type(h) == "number" and (ll == nil or ll == 0 or ll == frames) then
      for dir, default in pairs(DEFAULT_INDEX) do
        local row = set[dir .. "_index"] or default --[[@as integer]]
        local anim = {
          type = "animation",
          name = "mb-edge-belt-" .. belt.name .. "-" .. dir,
          filename = a.filename,
          priority = a.priority,
          width = w,
          height = h,
          x = a.x or 0,
          y = (a.y or 0) + (row - 1) * h,
          scale = a.scale,
          shift = a.shift and table.deepcopy(a.shift) or nil,
          frame_count = frames,
          line_length = frames,
          tint = a.tint and table.deepcopy(a.tint) or nil,
          flags = a.flags and table.deepcopy(a.flags) or nil,
        }
        protos[#protos + 1] = anim
        if set.alternate and frames % 2 == 0 then
          -- an `alternate` belt (turbo) draws every other tile half a cycle later (measured:
          -- its marks repeat every two tiles); the "-odd" copy is for tiles with x + y odd
          local odd = table.deepcopy(anim)
          odd.name = anim.name .. "-odd"
          odd.frame_sequence = {}
          for k = 1, frames do
            odd.frame_sequence[k] = (k - 1 + frames / 2) % frames + 1
          end
          protos[#protos + 1] = odd
        end
      end
    end
  end
end

data:extend(protos)
