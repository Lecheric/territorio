-- Base Beautification: pave the whole territory.
--
-- Once territorio-beautification is researched, every land tile of a force's owned
-- territory is set to stone brick (concrete / refined concrete at the higher tiers) --
-- free, and re-applied whenever the territory grows. Cosmetic plus the vanilla walking
-- bonus on paved ground.
--
-- No persistent state: the tier is read from `force.technologies`, and there is no
-- periodic re-assert -- tiles aren't destroyed by biters, and a tile the player changes
-- on purpose (hazard markings, a different floor) is left alone. Runs on research, on
-- territory change, and on init / configuration change.
--
-- Hazard-concrete markings are preserved; water is skipped (no landfill).

local util = require("scripts.util")
local state = require("scripts.state")

local beautify = {}

local CHUNK = util.CHUNK_SIZE

-- Player-placed floors we never pave over.
local PRESERVE = {
  ["hazard-concrete-left"] = true,
  ["hazard-concrete-right"] = true,
  ["refined-hazard-concrete-left"] = true,
  ["refined-hazard-concrete-right"] = true,
}

--- The tile this force's territory should be paved with, or nil if no tier is researched.
function beautify.target_tile(force)
  local techs = force.technologies
  if not techs then return nil end
  -- `-N` names are the merged-tech-tree-card naming (see prototypes/technologies.lua);
  -- these are still three separate, independently-researched technologies.
  local r = techs["territorio-beautification-3"]
  if r and r.researched then return "refined-concrete" end
  local c = techs["territorio-beautification-2"]
  if c and c.researched then return "concrete" end
  local s = techs["territorio-beautification"]
  if s and s.researched then return "stone-path" end
  return nil
end

--- Pave one force's territory on one surface to its researched tier.
function beautify.apply(surface_index, force)
  if state.is_ai_force(force.name) then return end
  local target = beautify.target_tile(force)
  if not target then return end

  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local owned = by_force and by_force[force.name]
  if not owned then return end

  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end

  -- One set_tiles call per owned chunk (not one giant call) so a large territory paves
  -- in smaller bites and a bad chunk can't lose the whole batch.
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local ox, oy = cx * CHUNK, cy * CHUNK
      local tiles, n = {}, 0
      for dx = 0, CHUNK - 1 do
        for dy = 0, CHUNK - 1 do
          local tx, ty = ox + dx, oy + dy
          local cur = surface.get_tile(tx, ty)
          if cur.valid and cur.name ~= target and not PRESERVE[cur.name]
              and not cur.collides_with("water_tile") then
            n = n + 1
            tiles[n] = { name = target, position = { tx, ty } }
          end
        end
      end
      if n > 0 then surface.set_tiles(tiles, true) end
    end
  end
end

function beautify.apply_force(force)
  if state.is_ai_force(force.name) then return end
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then beautify.apply(surface_index, force) end
  end
end

function beautify.apply_all()
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    for force_name in pairs(by_force) do
      local force = game.forces[force_name]
      if force and force.valid then beautify.apply(surface_index, force) end
    end
  end
end

return beautify
