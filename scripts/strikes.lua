-- Phase 4a: kills -> off-map artillery strike.
--
-- Pollution drifts into locked chunks the player can't touch, so nests grow unchecked and
-- pre-artillery there is no offensive answer. This is the valve: every enemy killed by a
-- player force feeds a point pool; at a threshold the force banks a strike charge (capped).
-- Arming the Strike tool (scripts/gui.lua) and clicking the map spends a charge to rain a
-- short barrage of vanilla artillery shells on that spot. No off-map turret entity -- the
-- shells are created directly.
--
-- All numbers first-pass; expect tuning against a real playthrough.

local state = require("scripts.state")

local strikes = {}

-- Points per enemy killed. Deliberately biter-weighted: charges should come from surviving
-- waves at your border, not from what a strike itself kills. A ~3-nest cluster + escorts
-- (the spread of one strike) must stay well under one charge, or strikes feed themselves.
-- Vanilla per-tier names; TYPE_POINTS catches modded / off-Nauvis enemies on "enemy" force.
local KILL_POINTS = {
  ["small-biter"] = 1, ["medium-biter"] = 2, ["big-biter"] = 4, ["behemoth-biter"] = 8,
  ["small-spitter"] = 1, ["medium-spitter"] = 2, ["big-spitter"] = 4, ["behemoth-spitter"] = 8,
  ["small-worm-turret"] = 2, ["medium-worm-turret"] = 4,
  ["big-worm-turret"] = 8, ["behemoth-worm-turret"] = 12,
  ["biter-spawner"] = 5, ["spitter-spawner"] = 5,
}
local TYPE_POINTS = { unit = 2, turret = 4, ["unit-spawner"] = 5 }

-- Playtest 4: 18 charges banked by the time tier 1 unlocked (~3h10m, ~2000 kills), and
-- only 5 cleared every remaining nest. ~2160 points earned, so 300/charge lands that same
-- run at ~7 -- still a comfortable surplus over the 5 actually needed, without the pool
-- reading as free. Note the kills were ~95% turret, so the hand-kill x2 barely moved this;
-- the base rate was what was generous.
local POINTS_PER_CHARGE = 300
local MAX_CHARGES = 99  -- effectively uncapped (was 3); the point curve still bounds banking

-- A kill you land yourself is worth more than one your wall of turrets landed for you --
-- the valve should reward going out and fighting at the front, not only holding a line.
-- `event.cause` is the CHARACTER for a hand-fired weapon (gun, grenade, capsule); a turret
-- or a driven vehicle reports its own entity instead, so this can't be farmed from a car.
local HAND_KILL_MULTIPLIER = 2

-- Strike strength by researched tech. First match (highest tier) wins. Since playtest 5
-- all three tiers cost the full five-pack spread and gate on production + utility -- the
-- Strike is the late-game capstone and the Missile Battery covers the middle of the run --
-- so the tiers separate on research COST, not on science pack. Kills still bank charges
-- before any of this is researched; you just can't fire.
-- The `-N` names are the merged-tech-tree-card naming (see prototypes/technologies.lua);
-- these are still three separate, independently-researched technologies.
--
-- `points` is that tier's kills-per-charge cost (playtest 5): the higher tiers do not just
-- fire harder, they also fill the bar faster, so the ladder is felt between barrages and
-- not only inside one. POINTS_PER_CHARGE above is the un-researched rate -- kills bank
-- before you can fire, and that pool should not be cheap.
local TIERS = {
  { tech = "territorio-artillery-strike-3", shells = 16, radius = 20, points = 150 },
  { tech = "territorio-artillery-strike-2", shells = 8,  radius = 10, points = 220 },
  { tech = "territorio-artillery-strike",   shells = 3,  radius = 6,  points = 300 },
}

local random = math.random
local cos, sin, pi = math.cos, math.sin, math.pi

local function strike_tier(force)
  for _, tier in ipairs(TIERS) do
    local t = force.technologies[tier.tech]
    if t and t.researched then return tier end
  end
  return nil
end

--- Has this force unlocked the artillery strike at all?
function strikes.unlocked(force)
  return strike_tier(force) ~= nil
end

--- Kills-per-charge for this force right now. Researching a higher tier lowers it, so a
--- pool banked at the old rate can bank several charges on the next kill -- the while loop
--- in on_entity_died handles that, and it reads as the reward it is.
local function points_per_charge(force)
  local tier = strike_tier(force)
  return tier and tier.points or POINTS_PER_CHARGE
end

function strikes.get_charges(force)
  return storage.territorio.strike_charges[force.name] or 0
end

--- Progress toward the next charge as a 0..1 fraction, plus whether the pool is capped.
function strikes.progress(force)
  local t = storage.territorio
  if (t.strike_charges[force.name] or 0) >= MAX_CHARGES then return 1, true end
  return (t.strike_points[force.name] or 0) / points_per_charge(force), false
end

--- Credit a kill. Returns the force if a charge was just banked (so the caller can refresh
--- that force's GUI), else nil.
function strikes.on_entity_died(event)
  local ent = event.entity
  if not (ent and ent.valid) or ent.force.name ~= "enemy" then return end

  local killer = event.force
  if not (killer and killer.valid) and event.cause and event.cause.valid then
    killer = event.cause.force
  end
  if not (killer and killer.valid) or state.is_ai_force(killer.name) then return end

  local points = KILL_POINTS[ent.name] or TYPE_POINTS[ent.type]
  if not points then return end

  local cause = event.cause
  if cause and cause.valid and cause.type == "character" then
    points = points * HAND_KILL_MULTIPLIER
  end

  local t = storage.territorio
  local charges = t.strike_charges[killer.name] or 0
  if charges >= MAX_CHARGES then return end -- full: ignore the kill entirely

  local pool = (t.strike_points[killer.name] or 0) + points
  local per_charge = points_per_charge(killer)
  local banked = false
  while pool >= per_charge and charges < MAX_CHARGES do
    pool = pool - per_charge
    charges = charges + 1
    banked = true
  end

  if charges >= MAX_CHARGES then pool = 0 end -- capped: don't carry leftover progress
  t.strike_points[killer.name] = pool
  t.strike_charges[killer.name] = charges

  if banked then
    killer.print({ "territorio-message.strike-ready", charges })
    return killer
  end
end

--- Spend a charge and bombard `position`. Returns true, or false + a reason key.
function strikes.call_strike(player, position)
  local force = player.force
  local tier = strike_tier(force)
  if not tier then return false, "territorio-message.strike-locked" end

  local t = storage.territorio
  local charges = t.strike_charges[force.name] or 0
  if charges < 1 then return false, "territorio-message.no-strike" end
  t.strike_charges[force.name] = charges - 1

  local surface = player.surface
  -- Shells arc in from the player's own base -- always in generated, owned territory, and
  -- it reads as "your artillery" rather than materialising next to the map cursor. Also
  -- makes blind scouting shots into the black land where you aimed, not near the camera.
  -- If the player's body is on another surface (Remote View / off-planet), there is no
  -- base to fire from -- fall back to the force spawn on the target surface.
  local origin
  if player.physical_surface and player.physical_surface.index == surface.index then
    local body = player.physical_position
    origin = { x = body.x, y = body.y }
  else
    origin = force.get_spawn_position(surface) or { x = 0, y = 0 }
  end

  for _ = 1, tier.shells do
    local a, d = random() * 2 * pi, random() * tier.radius
    surface.create_entity({
      name = "artillery-projectile",
      position = origin,
      target = { x = position.x + cos(a) * d, y = position.y + sin(a) * d },
      speed = 3,
      force = force,
      max_range = 20000,
    })
  end

  -- Chart the corridor from the base to the impact area (+2 chunks each side): the
  -- projectile's own reveal radius is a fixed vanilla prototype value we can't widen, so
  -- the "spotting round" reveal is done here -- you can see where a blind shot landed.
  local pad = 2 * 32
  force.chart(surface, {
    { math.min(origin.x, position.x) - pad, math.min(origin.y, position.y) - pad },
    { math.max(origin.x, position.x) + pad, math.max(origin.y, position.y) + pad },
  })
  return true
end

return strikes
