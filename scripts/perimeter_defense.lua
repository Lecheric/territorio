-- Perimeter Defense: dragon's teeth + tiered land mines.
--
-- Extends the already-shipped territorio-border-wall valve (scripts/walls.lua) with more
-- automated, free defense-in-depth projecting OUTWARD from the wall into the unclaimed
-- neighbour -- the "constant upkeep" of manually turret-lining a border, automated like
-- the wall itself. T1 (auto-repair) lives in walls.lua since it operates on the SAME
-- tracked wall entities; this module covers T2 (dragon's teeth) and T3/T4 (tiered land
-- mines), which are new entity classes at new offsets.
--
--   * Same idempotent refresh() shape as walls.lua: recomputes desired positions from
--     current territory + researched tier, adds/removes to match. Handles territory
--     growth/shrink and tier changes (e.g. researching -dense-mines fills the gaps
--     between existing mines) uniformly -- no separate migration path needed.
--   * Teeth/mines the player hand-mines are suppressed (like wall_suppressed) until that
--     tile stops being a desired position.
--   * Both project into the unclaimed neighbour, so a defensive check skips any tile
--     that (despite the open-edge test) turns out to already be owned -- complex
--     territory shapes can otherwise trip this up.
--
-- All numbers first-pass.

local util = require("scripts.util")
local state = require("scripts.state")

local perimeter_defense = {}

local CHUNK = util.CHUNK_SIZE
local TEETH = "stone-wall"
local MINE = "land-mine"
local floor, max = math.floor, math.max

-- Dragon's teeth: two rows that must LEAVE GAPS.
--
-- The first cut used adjacent depths (2 and 3) at step 2, and the lattice staggered them
-- one tile apart -- which turned out to be the bug, not the feature. Teeth a single tile
-- apart diagonally pinch tighter than a biter's collision box, so the field read as a
-- second solid wall with nothing to walk through. Biters chewed it instead of filing into
-- it, the exact opposite of the point: dragon's teeth are meant to break up and slow a
-- charge, not stop it.
--
-- Fixed by mirroring the Dense Minefield below: rows 2 apart at the SAME step, so the
-- global `(tx + ty) % step` lattice offsets the outer row 2 tiles sideways for free.
-- Step 4 leaves 3 clear tiles between teeth in a row, so a path always exists, and the
-- offset row means it is never a straight one.
local TEETH_RINGS = { { depth = 2, step = 4 }, { depth = 4, step = 4 } }

-- Mines sit where an attacker STOPS, and that is nearer than the raw spitter range
-- suggests. Vanilla ranges (small 13, medium 14, big 15, behemoth 16) measure to the
-- spitter's TARGET, and a spitter does not target the teeth -- it targets the turrets
-- behind your wall. Measured from a turret sitting a few tiles inside the border, the
-- stopping line lands around 8 to 10 tiles OUT, not 16 to 19. Playtest 5 confirmed the
-- first cut at depth 16 was simply too far to matter.
local MINE_DEPTH = 8
local MINE_STEP = 4

-- Dense Minefield adds a SECOND row rather than halving the spacing, so the field zig-zags
-- instead of just getting tighter. +2 depth at the same step is exactly "2 tiles further
-- out, 2 tiles to the side": moving the depth by 2 shifts the (tx + ty) lattice phase by 2
-- for free. Also reaches the deeper end of the stopping band at depth 10.
local MINE_DENSE_GAP = 2

-- Same edge detection as walls.lua's EDGES, duplicated locally (small, self-contained --
-- matches how overlay.lua/walls.lua/surveillance.lua each keep their own geometry table).
local EDGES = {
  { dx = 0,  dy = -1, axis = "y", fixed = 0 },          -- north edge
  { dx = 0,  dy = 1,  axis = "y", fixed = CHUNK - 1 },  -- south edge
  { dx = -1, dy = 0,  axis = "x", fixed = 0 },          -- west edge
  { dx = 1,  dy = 0,  axis = "x", fixed = CHUNK - 1 },  -- east edge
}
local SIGNS = { -1, 1 }

local function tile_key(tx, ty)
  return tx .. "," .. ty
end

-- Chebyshev distance from a tile to the nearest owned chunk >= depth?
--
-- WHY: projecting each open edge straight outward is only correct along a straight run.
-- At a CONCAVE corner the two arms' projections run right up against (and across) each
-- other's territory -- teeth crowding the inside corner, mines drawing a "T" back into
-- the wall. Measuring true distance to the whole territory instead trims both cleanly.
-- Only the 3x3 chunk neighbourhood needs checking: any chunk outside it has its nearest
-- tile >= 32 away, so it cannot be closer than `depth`. **That holds only while depth < 32**
-- -- worth stating now that mines reach depth 18 rather than the single digits this was
-- first written for. Any future depth at or past 32 needs a 5x5 scan.
local function far_enough(owned, tx, ty, depth)
  local ccx, ccy = floor(tx / CHUNK), floor(ty / CHUNK)
  for ax = -1, 1 do
    for ay = -1, 1 do
      local qx, qy = ccx + ax, ccy + ay
      if owned[util.chunk_key(qx, qy)] then
        local bx, by = qx * CHUNK, qy * CHUNK
        local dx = max(bx - tx, tx - (bx + CHUNK - 1), 0)
        local dy = max(by - ty, ty - (by + CHUNK - 1), 0)
        if max(dx, dy) < depth then return false end
      end
    end
  end
  return true
end

--- Tile-key set for a ring at Chebyshev distance `depth` outside the territory, thinned
--- to every `step`-th tile. `step <= 0` means "nothing" (tier not researched).
---
--- Straight runs come from each open edge; the corner elbows come from the convex-corner
--- blocks (without them the ring leaves a depth x depth hole at every outside corner --
--- a ~7-tile diagonal gap at depth 5). Spacing uses a global (tx+ty) lattice rather than
--- a per-chunk counter so runs stay evenly spaced across chunk seams and around corners.
local function offset_tiles(owned, depth, step)
  local result = {}
  if step <= 0 then return result end

  local function consider(tx, ty)
    -- Cheap lattice test first -- it rejects most candidates before the 9-chunk scan.
    if (tx + ty) % step ~= 0 then return end
    if far_enough(owned, tx, ty, depth) then result[tile_key(tx, ty)] = true end
  end

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local ox, oy = cx * CHUNK, cy * CHUNK

      -- Straight runs: each open edge's own 32-tile span, pushed out `depth` tiles.
      for _, e in ipairs(EDGES) do
        if not owned[util.chunk_key(cx + e.dx, cy + e.dy)] then
          -- e.dx/e.dy already carries the correct -1/+1 sign for the "low"/"high" side.
          local off = e.fixed + (e.dx + e.dy) * depth
          for i = 0, CHUNK - 1 do
            if e.axis == "y" then consider(ox + i, oy + off) else consider(ox + off, oy + i) end
          end
        end
      end

      -- Convex corner elbows: the outer L of the depth x depth corner block, which is
      -- exactly the tiles at Chebyshev distance `depth` diagonally off the corner. Joins
      -- the two straight runs so the ring turns the corner instead of leaving a hole.
      for _, sx in ipairs(SIGNS) do
        for _, sy in ipairs(SIGNS) do
          if not owned[util.chunk_key(cx + sx, cy)]
              and not owned[util.chunk_key(cx, cy + sy)] then
            local bx = (sx == 1) and (ox + CHUNK - 1) or ox
            local by = (sy == 1) and (oy + CHUNK - 1) or oy
            for dx = 1, depth do
              for dy = 1, depth do
                if dx == depth or dy == depth then
                  consider(bx + sx * dx, by + sy * dy)
                end
              end
            end
          end
        end
      end
    end
  end

  return result
end

--- Union of several rings into one desired-tile set. Rings are independent passes rather
--- than one clever pattern, so adding or moving a row is a one-line change to the tables
--- above and the corner/concavity handling in offset_tiles is inherited by every row.
local function ring_union(owned, rings)
  local result = {}
  for _, r in ipairs(rings) do
    for key in pairs(offset_tiles(owned, r.depth, r.step)) do result[key] = true end
  end
  return result
end

--- Has this force researched the dragon's-teeth tier?
function perimeter_defense.teeth_enabled(force)
  local tech = force.technologies and force.technologies["territorio-perimeter-defense-teeth"]
  return tech ~= nil and tech.researched
end

--- The mine rows this force has earned: none, one, or the base row plus the offset
--- zig-zag row that Dense Minefield adds.
function perimeter_defense.mine_rings(force)
  local techs = force.technologies
  if not techs then return {} end
  local base = techs["territorio-perimeter-defense-mines"]
  if not (base and base.researched) then return {} end

  local rings = { { depth = MINE_DEPTH, step = MINE_STEP } }
  local dense = techs["territorio-perimeter-defense-dense-mines"]
  if dense and dense.researched then
    rings[#rings + 1] = { depth = MINE_DEPTH + MINE_DENSE_GAP, step = MINE_STEP }
  end
  return rings
end

local function ensure_tables(t, si, fname)
  t.perimeter_teeth[si] = t.perimeter_teeth[si] or {}
  t.perimeter_teeth[si][fname] = t.perimeter_teeth[si][fname] or {}
  t.perimeter_teeth_suppressed[si] = t.perimeter_teeth_suppressed[si] or {}
  t.perimeter_teeth_suppressed[si][fname] = t.perimeter_teeth_suppressed[si][fname] or {}
  t.perimeter_mines[si] = t.perimeter_mines[si] or {}
  t.perimeter_mines[si][fname] = t.perimeter_mines[si][fname] or {}
  t.perimeter_mines_suppressed[si] = t.perimeter_mines_suppressed[si] or {}
  t.perimeter_mines_suppressed[si][fname] = t.perimeter_mines_suppressed[si][fname] or {}
  return t.perimeter_teeth[si][fname], t.perimeter_teeth_suppressed[si][fname],
    t.perimeter_mines[si][fname], t.perimeter_mines_suppressed[si][fname]
end

-- Shared add/remove sync for one (entity_name, tracked, suppressed, desired) set. Used
-- for both teeth and mines below -- same idempotent shape as walls.lua's inline logic.
local function sync(surface, force, entity_name, tracked, suppressed, desired)
  for key in pairs(desired) do
    if not suppressed[key] then
      local e = tracked[key]
      if not (e and e.valid) then
        local sx, sy = key:match("^(-?%d+),(-?%d+)$")
        local pos = { x = tonumber(sx) + 0.5, y = tonumber(sy) + 0.5 }
        if surface.can_place_entity({
          name = entity_name, position = pos, force = force,
          build_check_type = defines.build_check_type.manual,
        }) then
          tracked[key] = surface.create_entity({ name = entity_name, position = pos, force = force })
        end
      end
    end
  end
  for key, e in pairs(tracked) do
    if not desired[key] then
      if e and e.valid then e.destroy() end
      tracked[key] = nil
    end
  end
  for key in pairs(suppressed) do
    if not desired[key] then suppressed[key] = nil end
  end
end

--- Bring one force's teeth + mines (on one surface) into sync with territory + tiers.
--- Idempotent: safe on expansion, on research, and repeatedly from the sweep.
function perimeter_defense.refresh(surface_index, force)
  if state.is_ai_force(force.name) then return end

  local t = storage.territorio
  if not t then return end

  local owned = t.unlocked_chunks[surface_index] and t.unlocked_chunks[surface_index][force.name]
  if not owned then return end

  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end

  local teeth_tracked, teeth_suppressed, mine_tracked, mine_suppressed =
    ensure_tables(t, surface_index, force.name)

  local teeth_rings = perimeter_defense.teeth_enabled(force) and TEETH_RINGS or {}
  sync(surface, force, TEETH, teeth_tracked, teeth_suppressed, ring_union(owned, teeth_rings))

  sync(surface, force, MINE, mine_tracked, mine_suppressed,
    ring_union(owned, perimeter_defense.mine_rings(force)))
end

function perimeter_defense.refresh_force(force)
  if state.is_ai_force(force.name) then return end
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then perimeter_defense.refresh(surface_index, force) end
  end
end

function perimeter_defense.refresh_all()
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    for force_name in pairs(by_force) do
      local force = game.forces[force_name]
      if force and force.valid then perimeter_defense.refresh(surface_index, force) end
    end
  end
end

--- Territory changed (chunk bought / dev unlock): the geometry is stateless (unlike
--- surveillance's cached sweep list), so just re-syncing is enough.
function perimeter_defense.on_territory_changed(surface_index, force)
  perimeter_defense.refresh(surface_index, force)
end

--- on_player_mined_entity / on_robot_mined_entity, filtered to stone-wall + land-mine. If
--- the mined entity is one WE placed (teeth or mine), record the tile as manually cleared
--- so the sweep leaves it open. Silently ignores the primary wall ring (walls.lua's own
--- table won't have these positions, and vice versa) and anything not ours.
function perimeter_defense.on_mined(event)
  local ent = event.entity
  if not (ent and ent.valid) then return end
  if ent.name ~= TEETH and ent.name ~= MINE then return end

  local t = storage.territorio
  if not t then return end

  local force = ent.force
  local si = ent.surface.index
  local key = tile_key(floor(ent.position.x), floor(ent.position.y))

  local tracked_root = (ent.name == TEETH) and t.perimeter_teeth or t.perimeter_mines
  local suppressed_root = (ent.name == TEETH) and t.perimeter_teeth_suppressed or t.perimeter_mines_suppressed

  local tracked = tracked_root[si] and tracked_root[si][force.name]
  if not tracked or tracked[key] == nil then return end -- not ours / not tracked

  tracked[key] = nil
  suppressed_root[si] = suppressed_root[si] or {}
  suppressed_root[si][force.name] = suppressed_root[si][force.name] or {}
  suppressed_root[si][force.name][key] = true
end

--- Slow sweep: rebuild teeth/mines biters have broken, follow territory/tier changes.
function perimeter_defense.on_nth_tick()
  perimeter_defense.refresh_all()
end

return perimeter_defense
