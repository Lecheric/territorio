-- Phase 4b: automated border wall.
--
-- Pollution drifts into locked chunks the player can't reach, so nests grow there and the
-- mid-game biter ramp overruns a base that can't expand to clear them. This is the cheap
-- early defensive valve (the strike in scripts/strikes.lua is the offensive one): once
-- `territorio-border-wall` is researched, keep a free vanilla stone-wall ring on the
-- outermost owned tiles of the force's territory.
--
--   * refresh() is the single idempotent worker -- it both extends the ring onto new
--     perimeter and pulls it back off tiles that expansion turned interior.
--   * a slow on_nth_tick sweep re-runs refresh for every force, and heals damaged walls
--     a fraction at a time.
--   * a wall the biters DESTROY is not automatically rebuilt by this tech -- patching
--     breaches by hand is the early-game cost of the free wall. Perimeter Defense tier 1
--     (walls.replace_enabled) buys that back. `tracked[key] == false` marks a tile we
--     walled once and lost, so the rebuild tier can pick it up later.
--   * walls the PLAYER hand-mines are recorded in wall_suppressed and NOT rebuilt, so a
--     deliberate gap stays a gap until that tile stops being a perimeter tile.
--   * tiles blocked by water / cliffs / the player's own machines are skipped (can't
--     place) -- no clearing of trees/rocks, no destroying player entities.
--
-- All numbers first-pass; expect tuning against a real playthrough.

local util = require("scripts.util")
local state = require("scripts.state")

local walls = {}

local WALL = "stone-wall"
local CHUNK = util.CHUNK_SIZE
local floor = math.floor

-- Fraction of max health healed per sweep (see repair_force).
local REPAIR_FRACTION = 0.10

-- Neighbour offset + the inner-edge tile line to wall when that neighbour is unowned.
-- `fixed` names the axis pinned to the chunk edge; the other axis sweeps 0..CHUNK-1.
local EDGES = {
  { dx = 0,  dy = -1, axis = "y", fixed = 0 },          -- north edge: ty = oy
  { dx = 0,  dy = 1,  axis = "y", fixed = CHUNK - 1 },  -- south edge: ty = oy + 31
  { dx = -1, dy = 0,  axis = "x", fixed = 0 },          -- west edge:  tx = ox
  { dx = 1,  dy = 0,  axis = "x", fixed = CHUNK - 1 },  -- east edge:  tx = ox + 31
}

local function tile_key(tx, ty)
  return tx .. "," .. ty
end

--- Set of "tx,ty" keys for the tiles that should carry a border wall right now: the
--- inner-edge tile line of every owned chunk edge whose NSEW neighbour is not owned.
local function perimeter_tiles(owned)
  local result = {}
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local ox, oy = cx * CHUNK, cy * CHUNK
      for _, e in ipairs(EDGES) do
        if not owned[util.chunk_key(cx + e.dx, cy + e.dy)] then
          if e.axis == "y" then
            local ty = oy + e.fixed
            for i = 0, CHUNK - 1 do result[tile_key(ox + i, ty)] = true end
          else
            local tx = ox + e.fixed
            for i = 0, CHUNK - 1 do result[tile_key(tx, oy + i)] = true end
          end
        end
      end
    end
  end
  return result
end

--- Has this force researched the border wall?
function walls.enabled(force)
  local tech = force.technologies and force.technologies["territorio-border-wall"]
  return tech ~= nil and tech.researched
end

--- Has this force researched Perimeter Defense tier 1 (rebuild destroyed sections)?
--- The base border-wall tech builds the ring and heals damage, but a section the biters
--- actually DESTROY stays a hole until this is researched -- patching breaches by hand is
--- the early-game cost of the wall, and this tech is what buys that back.
function walls.replace_enabled(force)
  local tech = force.technologies and force.technologies["territorio-perimeter-defense"]
  return tech ~= nil and tech.researched
end

--- Heal damaged (not destroyed) tracked walls, REPAIR_FRACTION of max health per sweep --
--- ~35 HP per 10 s on a 350 HP stone-wall, so a mauled section knits back over ~100 s
--- rather than snapping to full. Part of the base border-wall tech.
-- ("Increase wall HP" isn't achievable -- stone-wall is vanilla and its max_health can't
-- be touched -- so healing is the closest real equivalent.)
local function repair_force(force)
  if not walls.enabled(force) then return end
  local t = storage.territorio
  for _, by_force in pairs(t.border_walls) do
    local tracked = by_force[force.name]
    if tracked then
      for _, e in pairs(tracked) do
        if e and e ~= false and e.valid then
          local max_health = e.prototype.get_max_health()
          if e.health < max_health then
            e.health = math.min(max_health, e.health + max_health * REPAIR_FRACTION)
          end
        end
      end
    end
  end
end

local function ensure_tables(t, si, fname)
  t.border_walls[si] = t.border_walls[si] or {}
  t.border_walls[si][fname] = t.border_walls[si][fname] or {}
  t.wall_suppressed[si] = t.wall_suppressed[si] or {}
  t.wall_suppressed[si][fname] = t.wall_suppressed[si][fname] or {}
  return t.border_walls[si][fname], t.wall_suppressed[si][fname]
end

local function clear_all(tracked)
  for key, e in pairs(tracked) do
    if e and e ~= false and e.valid then e.destroy() end
    tracked[key] = nil
  end
end

--- Bring the border-wall ring for one force on one surface into sync with its territory.
--- Idempotent: safe to call on expansion, on research, and repeatedly from the sweep.
function walls.refresh(surface_index, force)
  if state.is_ai_force(force.name) then return end

  local t = storage.territorio
  if not t then return end

  local by_force = t.border_walls[surface_index]
  local existing = by_force and by_force[force.name]

  if not walls.enabled(force) then
    -- Un-researched (console) or never researched: tear down anything we placed.
    if existing then clear_all(existing) end
    return
  end

  local owned = t.unlocked_chunks[surface_index] and t.unlocked_chunks[surface_index][force.name]
  if not owned then return end

  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end

  local tracked, suppressed = ensure_tables(t, surface_index, force.name)
  local desired = perimeter_tiles(owned)

  local replace = walls.replace_enabled(force)

  local function build(key)
    local sx, sy = key:match("^(-?%d+),(-?%d+)$")
    local pos = { x = tonumber(sx) + 0.5, y = tonumber(sy) + 0.5 }
    if surface.can_place_entity({
      name = WALL, position = pos, force = force,
      build_check_type = defines.build_check_type.manual,
    }) then
      tracked[key] = surface.create_entity({ name = WALL, position = pos, force = force })
      return true
    end
    return false
  end

  -- Build out to new perimeter, and (only with the rebuild tier) re-close breaches.
  -- `nil` = never built here; `false` = we built one and the biters destroyed it. That
  -- distinction is the whole point: the base tech always extends the ring onto ground it
  -- has never walled, but leaves a destroyed section as the player's problem.
  for key in pairs(desired) do
    if not suppressed[key] then
      local e = tracked[key]
      if e == nil then
        build(key)
      elseif e == false or not e.valid then
        if replace then build(key) else tracked[key] = false end
      end
    end
  end

  -- Remove walls on tiles expansion turned interior, and forget any manual-removal
  -- record for a tile that is no longer on the perimeter.
  for key, e in pairs(tracked) do
    if not desired[key] then
      if e and e ~= false and e.valid then e.destroy() end
      tracked[key] = nil
    end
  end
  for key in pairs(suppressed) do
    if not desired[key] then suppressed[key] = nil end
  end
end

--- Refresh every surface this force owns territory on.
function walls.refresh_force(force)
  if state.is_ai_force(force.name) then return end
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then walls.refresh(surface_index, force) end
  end
end

--- Refresh every force on every surface. Used on init / config change / the slow sweep.
function walls.refresh_all()
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    for force_name in pairs(by_force) do
      local force = game.forces[force_name]
      if force and force.valid then walls.refresh(surface_index, force) end
    end
  end
end

--- on_player_mined_entity / on_robot_mined_entity (filtered to stone-wall). If the mined
--- wall is one we placed, record the tile as manually cleared so the sweep leaves it open.
function walls.on_mined(event)
  local ent = event.entity
  if not (ent and ent.valid) or ent.name ~= WALL then return end

  local force = ent.force
  local t = storage.territorio
  local by_force = t and t.border_walls[ent.surface.index]
  local tracked = by_force and by_force[force.name]
  if not tracked then return end

  local key = tile_key(floor(ent.position.x), floor(ent.position.y))
  if tracked[key] == nil then return end -- not our wall / not a tracked perimeter tile

  tracked[key] = nil
  local sup = t.wall_suppressed[ent.surface.index]
  sup = sup and sup[force.name]
  if not sup then
    t.wall_suppressed[ent.surface.index] = t.wall_suppressed[ent.surface.index] or {}
    t.wall_suppressed[ent.surface.index][force.name] = {}
    sup = t.wall_suppressed[ent.surface.index][force.name]
  end
  sup[key] = true
end

--- Slow sweep: rebuild biter-broken walls, fill tiles terrain gen has caught up on, and
--- (Perimeter Defense T1) heal damaged walls for forces that have researched auto-repair.
function walls.on_nth_tick()
  walls.refresh_all()
  local t = storage.territorio
  if not t then return end
  for _, force in pairs(game.forces) do
    if force.valid and not state.is_ai_force(force.name) then repair_force(force) end
  end
end

return walls
