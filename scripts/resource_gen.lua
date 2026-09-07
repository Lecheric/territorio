-- Playtest-3: the Ore Generator.
--
-- A tile-locked base can't afford the chunk tokens to expand toward distant ore/oil, so
-- playtest 2 devolved into 1-chunk-wide "cancer arming" tendrils. Fix: once
-- `territorio-resource-synthesis` is researched, arm the Synthesize tool (scripts/gui.lua),
-- pick a resource, and select an OWNED chunk on the map. It spends COST expansion tokens
-- (same pool as buying land -- a direct land-vs-resources choice) and fills that chunk
-- with a dense resource patch.
--
-- Deplete-but-rich, not self-regenerating: re-selecting a synthesized chunk with the same
-- resource tops the patch back up for another COST tokens (also handy to top up to a
-- higher level's richness once you've researched further).
--
-- Richness AND which resources are pickable both scale with a "level" read from 5
-- separately-researched tiers (prototypes/technologies.lua) gated behind an escalating
-- science-pack spread -- see resource_gen.level(). Solid ore starts modest (~120k, a
-- flat-rate v1 gave everyone ~20M from the start -- too much too early per playtest-3
-- feedback) and only the top tier reaches the top richness. The FIELD grows with research
-- too -- 20x20 at tier 1 up to 27x27 at tier 5 -- so a later tier buys both more ore per
-- tile and more room to park miners on. Oil is different: the original flat richness (6 wells @ 500k) already read
-- fine at the *start*, so oil begins there and grows by adding wells + per-well yield.
--
-- All numbers first-pass.

local util = require("scripts.util")
local state = require("scripts.state")
local tokens = require("scripts.tokens")

local resource_gen = {}

local CHUNK = util.CHUNK_SIZE
local COST = 2                -- expansion tokens per chunk synthesized or refilled
-- Field size in tiles per side, by researched level: research buys AREA as well as
-- richness, so a later tier both enriches an existing patch and grows its footprint (see
-- synthesize_chunk -- refill and place both always run, so re-selecting extends the edge).
-- Caps below the 32-tile chunk so a field never bleeds into a neighbouring chunk.
local FIELD_BY_LEVEL = { 20, 22, 24, 26, 27 }
local floor, ceil, max, random = math.floor, math.ceil, math.max, math.random

local MAX_LEVEL = 5

-- The 5 tiers are separate chained techs (prototypes/technologies.lua), `-N`-numbered and
-- `upgrade = true` so Factorio's tech-tree GUI merges them into one card (vanilla
-- mining-productivity-1..4 does the same) -- not levels of one repeatable tech, which
-- can't add a NEW ingredient type per level, and each tier here gates on a different
-- science pack. Ordered low -> high.
local LEVEL_TECHS = {
  "territorio-resource-synthesis",
  "territorio-resource-synthesis-2",
  "territorio-resource-synthesis-3",
  "territorio-resource-synthesis-4",
  "territorio-resource-synthesis-5",
}

-- Which tier first unlocks each resource in the picker.
local RESOURCE_UNLOCK_LEVEL = {
  ["iron-ore"]    = 1,
  ["coal"]        = 1,
  ["crude-oil"]   = 1,
  ["copper-ore"]  = 2,
  ["stone"]       = 2,
  ["uranium-ore"] = 3,
}

-- Per-tile amount for iron/copper at each researched level. Because FIELD_BY_LEVEL grows
-- too, the TOTAL scales on both axes.
--
-- Playtest 5 retune: the early tiers were too thin -- tier 2 had to be spent THREE times
-- on iron in a single run, which makes the Ore Generator feel like a leak rather than a
-- decision. Tier 1 is up 1.67x (150k -> 250k) and tier 2 up 2.55x (300k -> 765k).
--
-- Tiers 3 and 4 moved too, which is more than was asked for, and deliberately: raising
-- only 1 and 2 would have squashed the tier 2 -> 3 step to 1.6x while every other step was
-- ~3x, so the ladder would have gone flat exactly where the player is deciding whether to
-- keep investing. The whole curve is now a uniform ~3.06x per tier, anchored at both ends
-- (tier 5's 30000 is the original flat richness and is untouched). Revert 4060 / 10600 to
-- 2250 / 8200 for the literal minimal change.
--
-- Oil is a separate ladder (OIL_AMOUNT_BY_LEVEL / OIL_WELLS_BY_LEVEL) and is untouched.
local BASE_PER_TILE_BY_LEVEL = { 625, 1580, 4060, 10600, 30000 }
-- field side:                    20     22     24      26      27
-- totals:                       250k   765k  2.34M   7.17M   21.9M
-- step:                             3.06x  3.06x   3.06x   3.05x

-- Per-resource richness relative to iron/copper (same ratios the flat v1 numbers had).
local RESOURCE_FACTOR = {
  ["iron-ore"]    = 1,
  ["copper-ore"]  = 1,
  ["stone"]       = 25000 / 30000,
  ["coal"]        = 25000 / 30000,
  ["uranium-ore"] = 8000 / 30000,
}

-- crude-oil: level 1 is the validated original (6 wells @ 500k) -- oil reads fine at that
-- richness even early, so unlike solid ore it doesn't start low. Each level adds 2 wells
-- and raises the per-well amount (~1.5x), per playtest-3 feedback.
local OIL_WELLS_BY_LEVEL  = { 6, 8, 10, 12, 14 }
local OIL_AMOUNT_BY_LEVEL = { 500000, 750000, 1100000, 1700000, 2500000 }

-- Picker order in the widget sub-frame.
resource_gen.RESOURCES = { "iron-ore", "copper-ore", "stone", "coal", "crude-oil", "uranium-ore" }

--- Highest resource-synthesis tier this force has researched (0 if none). Each tier is
-- its own single-level tech, so a plain .researched check is stable (unlike a repeatable
-- tech's, which flips back to false between levels -- see LLM-current-sprint.md).
function resource_gen.level(force)
  local techs = force.technologies
  if not techs then return 0 end
  for lvl = MAX_LEVEL, 1, -1 do
    local t = techs[LEVEL_TECHS[lvl]]
    if t and t.researched then return lvl end
  end
  return 0
end

--- The tier that first unlocks `name` in the picker, or nil if it's not a known resource.
function resource_gen.unlock_level(name)
  return RESOURCE_UNLOCK_LEVEL[name]
end

--- Field side in tiles at `level`, or nil below tier 1. Exported for the Synthesize
--- overlay, which draws the footprint so the player can see where the ore will land
--- before spending on it.
function resource_gen.field_size(level)
  return FIELD_BY_LEVEL[level]
end

--- Expansion tokens one synthesize costs. Exported so the overlay's label cannot drift
--- away from what the tool actually charges.
resource_gen.COST = COST

local function valid_resource(name, level)
  local need = RESOURCE_UNLOCK_LEVEL[name]
  return need ~= nil and level >= need
end

local function solid_amount(resource, level)
  return floor(BASE_PER_TILE_BY_LEVEL[level] * RESOURCE_FACTOR[resource] + 0.5)
end

-- Top up any existing solid patch of `resource` in `area` (map-generated or previously
-- synthesized). Return value is informational now -- callers always run place_solid too.
local function refill_solid(surface, area, resource, level)
  local found = surface.find_entities_filtered({ area = area, name = resource })
  if #found == 0 then return false end
  local full = solid_amount(resource, level)
  for _, e in pairs(found) do
    if e.valid and e.amount < full then e.amount = full end
  end
  return true
end

local function place_solid(surface, cx, cy, resource, level)
  local ox = cx * CHUNK + CHUNK / 2
  local oy = cy * CHUNK + CHUNK / 2
  local amount = solid_amount(resource, level)
  -- Even-sided fields cannot sit perfectly symmetrically on the chunk centre, so the
  -- offsets are derived rather than a +/- half-extent: this lays exactly n x n tiles,
  -- centred as closely as an integer grid allows.
  local n = FIELD_BY_LEVEL[level]
  local lo = -floor((n - 1) / 2)
  local hi = lo + n - 1
  for dx = lo, hi do
    for dy = lo, hi do
      local p = { x = ox + dx, y = oy + dy }
      -- can_place_entity is false over water / cliffs / an existing (different) resource.
      if surface.can_place_entity({ name = resource, position = p }) then
        surface.create_entity({ name = resource, position = p, amount = amount })
      end
    end
  end
end

-- Oil scales in two dimensions (well count AND per-well amount), unlike solid ore (fixed
-- field, amount-only). Re-selecting a chunk tops up existing wells to the current level's
-- amount AND drills any additional wells the level now calls for.
local function augment_oil(surface, area, cx, cy, level)
  local found = surface.find_entities_filtered({ area = area, name = "crude-oil" })
  local amount = OIL_AMOUNT_BY_LEVEL[level]
  for _, e in pairs(found) do
    if e.valid and e.amount < amount then e.amount = amount end
  end

  local missing = OIL_WELLS_BY_LEVEL[level] - #found
  if missing > 0 then
    local base_x, base_y = cx * CHUNK, cy * CHUNK
    for _ = 1, missing do
      local p = { x = base_x + random(4, CHUNK - 4), y = base_y + random(4, CHUNK - 4) }
      if surface.can_place_entity({ name = "crude-oil", position = p }) then
        surface.create_entity({ name = "crude-oil", position = p, amount = amount })
      end
    end
  end
end

-- How far outside the chunk to look for drills that reach into it. Comfortably clears the
-- biggest vanilla mining radius (the big mining drill), and the search is one box per
-- synthesize click, so being generous costs nothing.
local DRILL_MARGIN = 8

-- Make drills over this ground notice the ore that just appeared under them.
--
-- A mining drill caches the resource entities in its reach when it is placed. Nothing in
-- vanilla makes ore appear under a standing drill, so the engine never re-scans, and a
-- drill sitting on a chunk we just synthesized keeps reporting "no mineable resources"
-- while its own tooltip simultaneously shows the new expected yield. Playtest 5: the fix
-- was to replace the drill by hand.
--
-- MEASURED, not guessed (playtest 5, two console probes): toggling `active` off and on
-- does NOT clear the cache. Teleporting the drill to its OWN position does. So the cache
-- is rebuilt on a position change, and a zero-distance teleport is the cheapest way to ask
-- for one -- nothing actually moves, and inventory, modules, circuit wires and health all
-- ride along with the entity.
local function refresh_drills(surface, force, area)
  local box = {
    { area[1][1] - DRILL_MARGIN, area[1][2] - DRILL_MARGIN },
    { area[2][1] + DRILL_MARGIN, area[2][2] + DRILL_MARGIN },
  }
  for _, drill in pairs(surface.find_entities_filtered({
    type = "mining-drill", force = force, area = box,
  })) do
    if drill.valid then drill.teleport(drill.position) end
  end
end

-- Synthesize / refill one chunk. Returns true, or false + a reason key.
local function synthesize_chunk(force, surface, cx, cy, resource, level)
  if not state.is_managed_surface(surface) then
    return false, "territorio-message.synth-bad-surface"
  end
  if not state.is_unlocked(surface.index, force.name, cx, cy) then
    return false, "territorio-message.synth-not-owned"
  end
  if tokens.get(force) < COST then
    return false, "territorio-message.synth-no-tokens"
  end

  local area = {
    { cx * CHUNK, cy * CHUNK },
    { cx * CHUNK + CHUNK, cy * CHUNK + CHUNK },
  }

  tokens.spend(force, COST)

  if resource == "crude-oil" then
    augment_oil(surface, area, cx, cy, level)
  else
    -- BOTH, always. This used to be `if not refill_solid(...) then place_solid(...)`, so a
    -- chunk that already held ANY tile of the resource -- a map-generated patch especially
    -- -- only ever got topped up and never grew. Synthesizing is supposed to enrich what is
    -- there AND extend the footprint; place_solid's can_place_entity check already skips
    -- occupied tiles, so running both is exactly "fill in the gaps and top up the rest".
    refill_solid(surface, area, resource, level)
    place_solid(surface, cx, cy, resource, level)
  end

  -- After BOTH branches: pumpjacks are mining drills too, so oil gets the same treatment.
  refresh_drills(surface, force, area)

  force.chart(surface, area)
  return true
end

--- on_player_selected_area for territorio-synthesize-tool.
function resource_gen.on_select(player, event)
  local t = storage.territorio
  local resource = t and t.synth_resource and t.synth_resource[player.index]

  local force = player.force
  local level = resource_gen.level(force)
  if level < 1 or not valid_resource(resource, level) then return end

  local surface = event.surface
  local lt, rb = event.area.left_top, event.area.right_bottom
  local cx0, cy0 = floor(lt.x / CHUNK), floor(lt.y / CHUNK)
  local cx1 = max(cx0, ceil(rb.x / CHUNK) - 1)
  local cy1 = max(cy0, ceil(rb.y / CHUNK) - 1)
  local center = { x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2 }

  local done, last_reason = 0, nil
  for cx = cx0, cx1 do
    for cy = cy0, cy1 do
      local ok, reason = synthesize_chunk(force, surface, cx, cy, resource, level)
      if ok then
        done = done + 1
      else
        last_reason = reason
        if reason == "territorio-message.synth-no-tokens" then break end
      end
    end
  end

  if done > 0 then
    player.create_local_flying_text({ text = { "territorio-message.synthesized", done }, position = center })
  elseif last_reason then
    player.create_local_flying_text({ text = { last_reason }, position = center })
  end
end

return resource_gen
