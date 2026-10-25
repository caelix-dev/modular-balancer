-- After `gui_connect`: removes the freeplay crash site (it lands when the player joins), repairs
-- what its fires damaged, and makes the character invulnerable. Body of an fdev `exec_lua` call.
local s = game.surfaces.nauvis
for _, e in pairs(s.find_entities_filtered({ area = { { -40, -50 }, { 200, 60 } } })) do
  if e.name:find("crash") or e.type == "fire" or e.type == "corpse" then
    e.destroy()
  elseif e.health and e.max_health and e.health < e.max_health then
    e.health = e.max_health
  end
end
for _, p in pairs(game.players) do
  if p.character then
    p.character.destructible = false
    p.character.teleport({ 20, 15 })
  end
end
return "ok"
