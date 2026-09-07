-- Control-phase behaviour for the Missile Battery. The turret itself is pure prototype
-- (prototypes/missile_battery.lua); this file handles the two things the data stage cannot.
--
--   1. DESTINATION REVEAL. Artillery shells reveal along their flight because
--      `artillery-projectile` sets reveal_map. The battery fires VANILLA rockets, and
--      adding that flag would mean editing a vanilla prototype -- banned. So the reveal is
--      done here instead, and only around the impact point: you see what you hit, not the
--      corridor you fired down. (Same technique strikes.lua uses for its corridor.)
--
--   2. THE SALVO ITSELF. The flare prototype is shots_per_flare = 1, so the remote alone
--      would fire a single missile. Eight missiles means eight flares: the capsule action
--      drops one on the click, this file rings it with seven more. That buys the spread and
--      the eight targeting flags on the map, using the flare's own vanilla sprite, for free.
--
--      Keep the ring TIGHT. A vanilla `rocket` only damages what it lands on -- it has no
--      area effect at all, which is why plain rockets read as doing nothing unless a shot
--      happens to land on a spawner. `explosive-rocket` is the one with a blast radius. A
--      wide pattern therefore wastes plain rockets outright and thins out explosive ones,
--      so SPREAD is sized to overlap rather than to cover ground.
--
--   3. PER-SALVO AMMO ROTATION. The engine drains the first non-empty ammo slot before
--      moving to the next, so one salvo is always one missile type -- there is no
--      round-robin and no "turret fired" event to script one from. Rotating the stacks once
--      per designation is the honest approximation: consecutive salvos lead with a
--      different type, so a mixed loadout still means something.
--
-- Both hang off on_player_used_capsule, which fires when the salvo remote is used. That is
-- the only signal available -- there is no event for a turret shooting.

local state = require("scripts.state")

local missile_battery = {}

local floor = math.floor

local BATTERY = "territorio-missile-battery"
local REMOTE = "territorio-missile-remote"
local FLARE = "territorio-missile-flare"
local TECH = "territorio-missile-battery"
local RANGE = 528          -- must match the gun's range in the prototype
local REVEAL_CHUNKS = 2    -- how far around the impact point to chart

-- The salvo pattern: the capsule's own flare lands dead centre, these seven ring it at
-- SPREAD tiles. 4.5 (playtest 5: half the original 9) puts the whole cluster inside ~10
-- tiles, which is roughly one explosive rocket's blast radius across -- so the eight
-- craters overlap into one hole instead of peppering a wide patch and killing nothing.
--
-- Unit vectors times a radius rather than sin/cos at runtime: trig is a classic
-- cross-platform float-determinism hazard in multiplayer, whereas an IEEE multiply is
-- exactly specified. Tuning the pattern is one number.
local SPREAD = 4.5
local SALVO_RING = {
  {  1.000,  0.000 },
  {  0.624,  0.782 },
  { -0.223,  0.975 },
  { -0.901,  0.434 },
  { -0.901, -0.434 },
  { -0.223, -0.975 },
  {  0.624, -0.782 },
}

--- Batteries of this force on this surface that could actually answer a designation at
--- `position`. Used both to decide whether to reveal and which turret to rotate.
local function batteries_in_range(surface, force, position)
  local found = {}
  for _, ent in pairs(surface.find_entities_filtered({ name = BATTERY, force = force })) do
    if ent.valid then
      local dx, dy = ent.position.x - position.x, ent.position.y - position.y
      if (dx * dx + dy * dy) <= RANGE * RANGE then
        found[#found + 1] = ent
      end
    end
  end
  return found
end

--- Shift the battery's ammo stacks one slot left, so the next salvo leads with what was
--- second. Reordering only -- nothing is created or destroyed.
local function rotate_ammo(battery)
  local inv = battery.get_inventory(defines.inventory.turret_ammo)
  if not inv then return end

  local stacks = {}
  for i = 1, #inv do
    local st = inv[i]
    if st and st.valid_for_read then
      stacks[#stacks + 1] = { name = st.name, count = st.count, quality = st.quality }
    end
  end
  if #stacks < 2 then return end   -- one type (or none) loaded: nothing to rotate

  stacks[#stacks + 1] = table.remove(stacks, 1)

  -- Write over the slots in place and clear only the tail. Deliberately NOT inv.clear()
  -- first: a failure midway through would then have thrown the ammo away, whereas
  -- overwriting can at worst leave the order untouched.
  local ok = pcall(function()
    for i = 1, #stacks do
      inv[i].set_stack(stacks[i])
    end
    for i = #stacks + 1, #inv do
      inv[i].clear()
    end
  end)
  return ok
end

--- Ring the designation with the rest of the salvo. Returns the error string if the engine
--- refused the flare, so the caller can surface it -- a silent failure here looks exactly
--- like "the battery only fires one missile", which is the bug this replaced.
---
--- A flare landing past the gun's max range is simply not answered, so the extreme edge of
--- the envelope can fire 7 instead of 8. At 4.5 tiles of spread on a 528-tile reach that is
--- under 1% of the range and not worth clamping for.
local function spread_salvo(surface, force, position)
  local err
  for _, o in ipairs(SALVO_RING) do
    local ok, e = pcall(function()
      surface.create_entity({
        name = FLARE,
        position = { x = position.x + o[1] * SPREAD, y = position.y + o[2] * SPREAD },
        force = force,
        -- Flares are projectile-like: the engine requires the full movement set even for a
        -- stationary marker. All zero = it sits where it is put.
        movement = { 0, 0 },
        height = 0,
        vertical_speed = 0,
        frame_speed = 0,
      })
    end)
    if not ok then
      err = e
      break
    end
  end
  return err
end

--- The salvo remote was used: reveal where it lands, and rotate for next time.
function missile_battery.on_player_used_capsule(event)
  if event.item and event.item.name ~= REMOTE then return end

  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  local surface = player.physical_surface or player.surface
  if not (surface and surface.valid and state.is_managed_surface(surface)) then return end

  local position = event.position
  if not position then return end

  local found = batteries_in_range(surface, player.force, position)
  if #found == 0 then return end   -- nothing of ours can reach: no reveal, no rotation

  local pad = REVEAL_CHUNKS * 32
  player.force.chart(surface, {
    { position.x - pad, position.y - pad },
    { position.x + pad, position.y + pad },
  })

  -- Only once something of ours can actually answer, so a designation out of reach does not
  -- litter the map with flags for missiles that are never coming.
  local err = spread_salvo(surface, player.force, position)
  if err then
    -- Deterministic (every peer runs this handler), and a broken salvo is worth saying out
    -- loud: the failure mode is indistinguishable from the single-missile bug otherwise.
    player.print("[Territorio] Missile salvo spread failed: " .. tostring(err))
  end

  for _, battery in pairs(found) do
    rotate_ammo(battery)
  end
end

--- Has the force researched the battery at all? A plain finite tech, so `.researched` is
--- honest here (unlike the repeatable ones, which flip back as the level pointer advances).
function missile_battery.unlocked(force)
  if not (force and force.valid) then return false end
  local tech = force.technologies[TECH]
  return tech ~= nil and tech.researched
end

--- Is there a battery of this force on this surface? Checked when the Salvo button is
--- CLICKED rather than every GUI refresh: a name-filtered surface search is not something
--- to run for every player several times a second, and "you have no battery here" is more
--- useful as a message than as a greyed-out button.
function missile_battery.present(surface, force)
  if not (surface and surface.valid and force and force.valid) then return false end
  return surface.count_entities_filtered({ name = BATTERY, force = force, limit = 1 }) > 0
end

missile_battery.REMOTE = REMOTE

-- The body is the rocket-silo BASE frame, and that frame has an open hole in the middle --
-- vanilla fills it with the silo's own doors and shadow, which we do not borrow, so the
-- terrain shows straight through. Laying a hazard pad under the whole footprint on
-- placement reads as a launch apron instead of a hole in the building.
--
-- Not reverted when the battery is mined: a leftover pad is a deliberate-looking marking,
-- and beautify.lua's PRESERVE already leaves hazard concrete alone.
local PAD = "hazard-concrete-left"

local function pave_footprint(entity)
  local surface = entity.surface
  local proto = entity.prototype
  local w, h = proto.tile_width, proto.tile_height
  local x0 = floor(entity.position.x - w / 2)
  local y0 = floor(entity.position.y - h / 2)

  local tiles, n = {}, 0
  for dx = 0, w - 1 do
    for dy = 0, h - 1 do
      local tx, ty = x0 + dx, y0 + dy
      local cur = surface.get_tile(tx, ty)
      if cur and cur.valid and cur.name ~= PAD and not cur.collides_with("water_tile") then
        n = n + 1
        tiles[n] = { name = PAD, position = { tx, ty } }
      end
    end
  end
  if n > 0 then surface.set_tiles(tiles, true) end
end

--- on_built_entity / on_robot_built_entity. Runs AFTER build_guard, which may have refunded
--- and destroyed the entity on this same tick -- hence the validity check rather than an
--- assumption that a built entity still exists.
function missile_battery.on_built(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.name == BATTERY) then return end
  pave_footprint(entity)
end

--- One battery per force per surface. Returns true if `entity` is a duplicate that should
--- be refused. No prototype field expresses this, so it is enforced at build time.
function missile_battery.is_duplicate(entity)
  if not (entity and entity.valid and entity.name == BATTERY) then return false end
  -- The entity being checked is already on the surface, so its own presence counts.
  return entity.surface.count_entities_filtered({
    name = BATTERY, force = entity.force,
  }) > 1
end

return missile_battery
