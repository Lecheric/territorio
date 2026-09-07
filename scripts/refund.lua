-- Chunk refund: sell an owned chunk back for the token you paid for it.
--
-- Three tiers, all refunding 1:1. What research changes is how much of the chunk SURVIVES
-- the sale -- one axis, deliberately: "mothballing". The reason to leave your factory
-- standing is that you can buy the chunk back later and find it intact.
--
--   T1  everything the force placed is destroyed, paving reverted.
--   T2  buildings stay (dead and unpowered); the wall ring is cleared.
--   T3  the wall ring stays too, so a mothballed chunk decays slowly rather than being
--       stripped by the first biter wave.
--
-- WHY the machines are switched off rather than left connected: a sold chunk that keeps
-- producing means sell -> rebuy elsewhere -> repeat, and territory becomes unlimited --
-- deleting the space constraint the whole mod is built on. Deactivating also means a
-- mothballed chunk emits no pollution, so it cannot quietly farm biters either.
--
-- Resources are never touched -- they are terrain, not player placement, and they sit on
-- the neutral force, so the force-filtered search below never sees them anyway.

local util = require("scripts.util")
local state = require("scripts.state")
local tokens = require("scripts.tokens")

local refund = {}

local CHUNK = util.CHUNK_SIZE

-- Highest researched wins. `-N` names + upgrade = true merge these into one tech-tree card
-- (see CLAUDE.md's tech-naming rule); they are still three independent techs.
local TIERS = {
  { tech = "territorio-chunk-refund-3", tier = 3 },
  { tech = "territorio-chunk-refund-2", tier = 2 },
  { tech = "territorio-chunk-refund",   tier = 1 },
}

-- Paving this mod (or the player) may have laid down. Only these revert at T1: reverting
-- EVERY covered tile would also undo landfill, dropping a chunk back into water along with
-- whatever was standing on it.
local PAVING = {
  ["stone-path"] = true, ["concrete"] = true, ["refined-concrete"] = true,
  ["hazard-concrete-left"] = true, ["hazard-concrete-right"] = true,
  ["refined-hazard-concrete-left"] = true, ["refined-hazard-concrete-right"] = true,
}

-- Never destroyed by a refund, whatever the tier: the player's own body, and bots that
-- merely happen to be flying over the chunk.
local SPARED_TYPES = {
  ["character"] = true,
  ["logistic-robot"] = true, ["construction-robot"] = true, ["combat-robot"] = true,
}

-- Only these answer get_driver / get_passenger; asking anything else is an error, not nil.
local RIDEABLE_TYPES = {
  ["car"] = true, ["spider-vehicle"] = true, ["locomotive"] = true,
  ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
}

--- Highest refund tier this force has researched (0 = none).
function refund.tier(force)
  local techs = force and force.technologies
  if not techs then return 0 end
  for _, t in ipairs(TIERS) do
    local tech = techs[t.tech]
    if tech and tech.researched then return t.tier end
  end
  return 0
end

function refund.unlocked(force)
  return refund.tier(force) > 0
end

local function chunk_area(cx, cy)
  return { { cx * CHUNK, cy * CHUNK }, { cx * CHUNK + CHUNK, cy * CHUNK + CHUNK } }
end

-- ---- connectivity -------------------------------------------------------------------

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

--- Would the force's territory still be one connected body, reachable from the starting
--- 2x2, if every chunk in `removing` were sold?
---
--- Purchases already require NSEW adjacency, so territory is connected BY CONSTRUCTION --
--- refund is the only operation that could ever break that. Checking here makes
--- connectivity a real invariant rather than an accident of the purchase rule, and stops a
--- player stranding chunks they could then never walk to.
local function stays_connected(owned, removing)
  local remaining, count = {}, 0
  for key in pairs(owned) do
    if not removing[key] then
      remaining[key] = true
      count = count + 1
    end
  end
  if count == 0 then return true end  -- sold the lot; nothing left to strand

  -- Anchor on a surviving seed chunk. state.is_seed_chunk keeps those unsellable, so one
  -- always survives unless the force owned nothing to begin with.
  local queue, seen, reached = {}, {}, 0
  for _, c in pairs(state.SEED_CHUNKS) do
    local key = util.chunk_key(c[1], c[2])
    if remaining[key] and not seen[key] then
      seen[key] = true
      queue[#queue + 1] = { c[1], c[2] }
    end
  end
  if #queue == 0 then return false end

  local head = 1
  while head <= #queue do
    local cur = queue[head]
    head = head + 1
    reached = reached + 1
    for _, o in pairs(OFFSETS) do
      local nx, ny = cur[1] + o[1], cur[2] + o[2]
      local nkey = util.chunk_key(nx, ny)
      if remaining[nkey] and not seen[nkey] then
        seen[nkey] = true
        queue[#queue + 1] = { nx, ny }
      end
    end
  end

  return reached == count
end

--- Set of "x,y" chunk keys this force could sell right now on this surface: owned, not a
--- seed chunk, and not load-bearing for the rest of the territory. Drives the map overlay
--- so the rule is visible instead of being discovered by a rejection message.
---
--- Cost is one flood-fill per owned chunk -- ~116 chunks squared at the token ceiling, so
--- a few thousand steps. Fine on a redraw, which only happens on arm/disarm and territory
--- change, but do NOT put this on a tick.
function refund.refundable(surface_index, force)
  local result = {}
  if refund.tier(force) == 0 then return result end

  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local owned = by_force and by_force[force.name]
  if not owned then return result end

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx and not state.is_seed_chunk(cx, cy) then
      if stays_connected(owned, { [key] = true }) then result[key] = true end
    end
  end
  return result
end

-- ---- teardown -----------------------------------------------------------------------

-- Drop this chunk's tiles out of the wall / teeth / mine tracking tables, optionally
-- destroying the entities. Done here rather than by calling into walls.lua and
-- perimeter_defense.lua so the refund feature stays self-contained; those tables are
-- shared state documented in scripts/state.lua.
local function clear_tracked(surface_index, force_name, cx, cy, destroy)
  local t = storage.territorio
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local x1, y1 = x0 + CHUNK - 1, y0 + CHUNK - 1

  local roots = {
    t.border_walls, t.wall_suppressed,
    t.perimeter_teeth, t.perimeter_teeth_suppressed,
    t.perimeter_mines, t.perimeter_mines_suppressed,
  }
  for _, root in pairs(roots) do
    local by_force = root and root[surface_index]
    local tracked = by_force and by_force[force_name]
    if tracked then
      for key, value in pairs(tracked) do
        -- Same "a,b" encoding as chunk keys, but these are TILE coordinates.
        local tx, ty = util.parse_chunk_key(key)
        if tx and tx >= x0 and tx <= x1 and ty >= y0 and ty <= y1 then
          -- `false` is walls.lua's "walled once, destroyed" sentinel, not an entity.
          if destroy and type(value) == "table" and value.valid then value.destroy() end
          tracked[key] = nil
        end
      end
    end
  end
end

--- Strip / mothball one chunk according to `tier`.
local function apply_tier(surface, force, cx, cy, tier)
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local x1, y1 = x0 + CHUNK, y0 + CHUNK

  -- T3 keeps the wall ring; T1/T2 clear it. Either way the tracking entries must go, or the
  -- sweeps keep dead references into a chunk this force no longer owns.
  clear_tracked(surface.index, force.name, cx, cy, tier < 3)

  for _, ent in pairs(surface.find_entities_filtered({ area = chunk_area(cx, cy), force = force })) do
    if ent.valid and not SPARED_TYPES[ent.type] then
      -- Judge by CENTRE, matching build_guard: an assembler straddling the border belongs
      -- to exactly one chunk, and both systems have to agree which one.
      local p = ent.position
      if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 then
        local occupied = RIDEABLE_TYPES[ent.type]
          and (ent.get_driver() or ent.get_passenger())
        if not occupied then
          if tier == 1 then
            ent.destroy()
          elseif ent.type == "electric-pole" then
            -- Cutting the poles is only half of "unpowered" -- deactivating below is the
            -- other half, since a pole in an adjacent OWNED chunk can still reach across.
            ent.destroy()
          else
            -- Not every entity type supports being inactive. A refund is a bulk operation
            -- and a mid-loop error would leave the territory half-sold, so one stubborn
            -- entity must not take the whole thing down.
            pcall(function() ent.active = false end)
          end
        end
      end
    end
  end

  if tier == 1 then
    local tiles = {}
    for x = x0, x1 - 1 do
      for y = y0, y1 - 1 do
        local tile = surface.get_tile(x, y)
        if tile and tile.valid and PAVING[tile.name] then
          local hidden = surface.get_hidden_tile({ x = x, y = y })
          if hidden then tiles[#tiles + 1] = { name = hidden, position = { x, y } } end
        end
      end
    end
    if #tiles > 0 then surface.set_tiles(tiles, true) end
  end
end

-- ---- entry point --------------------------------------------------------------------

--- Sell every chunk in `list` ({{cx, cy}, ...}) the force owns. Returns how many were sold,
--- plus a reason key when none were.
function refund.execute(player, list)
  local force = player.force
  local surface = player.surface
  local surface_index = surface.index

  local tier = refund.tier(force)
  if tier == 0 then return 0, "territorio-message.refund-locked" end
  if not state.is_managed_surface(surface) then
    return 0, "territorio-message.refund-bad-surface"
  end

  local t = storage.territorio
  local by_force = t.unlocked_chunks[surface_index]
  local owned = by_force and by_force[force.name]
  if not owned then return 0, "territorio-message.refund-not-owned" end

  -- Seed chunks are skipped rather than rejecting the whole selection: dragging a box that
  -- happens to cover spawn should sell the rest, not fail silently as one confusing error.
  local removing, n, hit_seed = {}, 0, false
  for _, c in pairs(list) do
    local key = util.chunk_key(c[1], c[2])
    if owned[key] and not removing[key] then
      if state.is_seed_chunk(c[1], c[2]) then
        hit_seed = true
      else
        removing[key] = true
        n = n + 1
      end
    end
  end
  if n == 0 then
    return 0, hit_seed and "territorio-message.refund-seed"
      or "territorio-message.refund-not-owned"
  end

  -- The whole selection is judged at once: checking one chunk at a time would make the
  -- verdict depend on iteration order.
  if not stays_connected(owned, removing) then
    return 0, "territorio-message.refund-would-strand"
  end

  for key in pairs(removing) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      owned[key] = nil
      apply_tier(surface, force, cx, cy, tier)
    end
  end

  tokens.add(force, n)

  -- Anyone whose bounce position now sits on sold ground would be teleported back to it
  -- every tick -- the same rubber-band trap the force-change path hit. Clearing it lets
  -- boundary.enforce fall through to nearest_owned_center and walk them home.
  for _, p in pairs(force.players) do
    local pos = t.last_valid_pos[p.index]
    if pos then
      local pcx, pcy = util.pos_to_chunk(pos)
      if removing[util.chunk_key(pcx, pcy)] then t.last_valid_pos[p.index] = nil end
    end
  end

  return n
end

--- Wake a mothballed chunk back up when the force buys it back.
---
--- Runs on EVERY purchase, including chunks that were never mothballed, so it meets plenty
--- of entities that are inherently inactive: `LuaEntity.active` is READ-ONLY on some types
--- (ghosts and similar), and writing it there is a hard error, not a silent no-op. That
--- crashed a plain expansion buy in playtest 4 (v0.1.36). Both the write here and the one
--- in apply_tier are pcall-guarded: an entity that refuses to change state is not a reason
--- to abort a purchase half-way.
function refund.on_chunk_reclaimed(surface, force, cx, cy)
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local x1, y1 = x0 + CHUNK, y0 + CHUNK
  for _, ent in pairs(surface.find_entities_filtered({ area = chunk_area(cx, cy), force = force })) do
    if ent.valid and not ent.active then
      local p = ent.position
      if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 then
        pcall(function() ent.active = true end)
      end
    end
  end
end

return refund
