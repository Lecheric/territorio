-- The territory edge, painted on the ground.
--
-- WHY THIS EXISTS (playtest 5): a player who has never seen the mod does not know there is
-- a boundary. The perimeter line in overlay.lua is `only_in_alt_mode`, and most players do
-- not turn alt mode on until their first production line is running -- so the first
-- experience of Territorio was walking into an invisible wall and assuming it was a bug.
--
-- So: a WIDTH-tile band of vanilla hazard concrete on the INSIDE edge of owned ground,
-- free from the first tick, no research. It reads as a factory hazard marking, which is
-- exactly what it is.
--
-- Why tiles rather than rendering: a drawn band would need hundreds of render objects per
-- player along a large border, would have to be re-drawn on every change, and we may not
-- author a chevron sprite. A tile costs nothing after it is placed, is visible in and out
-- of alt mode at every zoom, and hazard concrete already exists in vanilla.
--
-- Beautification never fights this: beautify.lua's PRESERVE set already skips all four
-- hazard-concrete variants, so a researched paving tier paves around the band.
--
-- ORDERING RULE: this must run AFTER beautify.apply in every fan-out. It records the tile
-- it painted over so it can put it back when the border moves, and if it ran first it
-- would record bare ground and later restore a grass line through a paved base.
--
-- No tick cost: refresh() runs on territory change, on research, and on init only. A
-- player who paves over the band keeps their floor until the border next moves.

local util = require("scripts.util")
local state = require("scripts.state")
local beautify = require("scripts.beautify")

local border_paint = {}

local PAINT = "hazard-concrete-left"
local CHUNK = util.CHUNK_SIZE

-- Band width in tiles, measured inward from the chunk edge. Two is already loud -- hazard
-- concrete is high contrast -- and this is the single number to change if it needs to be
-- wider.
local WIDTH = 2

-- Deliberate markings we put back verbatim instead of replacing with the paving tier.
-- Same four names as beautify.lua's PRESERVE, kept separate on purpose: that list means
-- "never pave over this", this one means "this was somebody's decision, restore it".
local MARKINGS = {
  ["hazard-concrete-left"] = true,
  ["hazard-concrete-right"] = true,
  ["refined-hazard-concrete-left"] = true,
  ["refined-hazard-concrete-right"] = true,
}

-- Neighbour offset + which end of the chunk the band hugs. `near` = the edge sits at
-- offset 0 and the band runs inward; otherwise it sits at CHUNK-1 and runs back.
local EDGES = {
  { dx = 0,  dy = -1, axis = "y", near = true },
  { dx = 0,  dy = 1,  axis = "y", near = false },
  { dx = -1, dy = 0,  axis = "x", near = true },
  { dx = 1,  dy = 0,  axis = "x", near = false },
}

local function tile_key(tx, ty)
  return tx .. "," .. ty
end

--- Set of "tx,ty" keys that should carry the band right now: the WIDTH innermost tile rows
--- of every owned chunk edge whose NSEW neighbour is not owned. A chunk with two unowned
--- neighbours gets both bands, and the corner is simply their union.
local function band_tiles(owned)
  local result = {}
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local ox, oy = cx * CHUNK, cy * CHUNK
      for _, e in ipairs(EDGES) do
        if not owned[util.chunk_key(cx + e.dx, cy + e.dy)] then
          for w = 0, WIDTH - 1 do
            local off = e.near and w or (CHUNK - 1 - w)
            if e.axis == "y" then
              for i = 0, CHUNK - 1 do result[tile_key(ox + i, oy + off)] = true end
            else
              for i = 0, CHUNK - 1 do result[tile_key(ox + off, oy + i)] = true end
            end
          end
        end
      end
    end
  end
  return result
end

local function ensure_table(t, si, fname)
  -- state.ensure_root creates this on init and on configuration change, so the guard is
  -- belt-and-braces -- but a nil index here would be a hard crash in a fan-out that runs
  -- on every chunk purchase, which is exactly the shape of bug this project keeps hitting.
  t.border_paint = t.border_paint or {}
  t.border_paint[si] = t.border_paint[si] or {}
  t.border_paint[si][fname] = t.border_paint[si][fname] or {}
  return t.border_paint[si][fname]
end

local function parse_key(key)
  local sx, sy = key:match("^(-?%d+),(-?%d+)$")
  return tonumber(sx), tonumber(sy)
end

--- Bring the band for one force on one surface into sync with its territory. Idempotent,
--- so it is safe to call from every fan-out and from init.
function border_paint.refresh(surface_index, force)
  if state.is_ai_force(force.name) then return end

  local t = storage.territorio
  if not t then return end

  local owned = t.unlocked_chunks[surface_index] and t.unlocked_chunks[surface_index][force.name]
  if not owned then return end

  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end

  local tracked = ensure_table(t, surface_index, force.name)
  local desired = band_tiles(owned)
  local paved = beautify.target_tile(force)   -- nil until Beautification is researched

  local writes, n = {}, 0

  -- Paint newly-perimeter ground, remembering what was underneath so the band can be
  -- lifted cleanly later. Water is skipped outright -- there is no landfill here.
  for key in pairs(desired) do
    if tracked[key] == nil then
      local tx, ty = parse_key(key)
      local cur = tx and surface.get_tile(tx, ty)
      if cur and cur.valid and not cur.collides_with("water_tile") then
        tracked[key] = cur.name
        if cur.name ~= PAINT then
          n = n + 1
          writes[n] = { name = PAINT, position = { tx, ty } }
        end
      end
    end
  end

  -- Lift the band off ground that expansion turned interior, otherwise old borders stay
  -- striped across the middle of the base. Restore the paving tier rather than the
  -- remembered tile when one is researched, since the tile was remembered before the
  -- research; a remembered MARKING was somebody's decision and goes back as it was.
  for key, prev in pairs(tracked) do
    if not desired[key] then
      local tx, ty = parse_key(key)
      if tx then
        local restore = prev
        if paved and not MARKINGS[prev] then restore = paved end
        n = n + 1
        writes[n] = { name = restore, position = { tx, ty } }
      end
      tracked[key] = nil
    end
  end

  if n > 0 then surface.set_tiles(writes, true) end
end

--- Refresh every surface this force owns territory on.
function border_paint.refresh_force(force)
  if state.is_ai_force(force.name) then return end
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then border_paint.refresh(surface_index, force) end
  end
end

--- Every force on every surface. Init / configuration change.
function border_paint.refresh_all()
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    for force_name in pairs(by_force) do
      local force = game.forces[force_name]
      if force and force.valid then border_paint.refresh(surface_index, force) end
    end
  end
end

return border_paint
