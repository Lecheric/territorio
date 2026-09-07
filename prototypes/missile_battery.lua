-- The Missile Battery -- the long-range rung between the Mortar and the artillery Strike.
--
-- WHAT IT FILLS: the Mortar is rationed by range, the Strike by kills. Nothing was
-- rationed by PRODUCTION, which is this mod's whole theme. The battery is: it burns real
-- rockets off your bus, so its firepower scales with the factory rather than with luck or
-- bodycount.
--
-- THE KEY TRICK: the gun's ammo_category is plain vanilla "rocket". `rocket`,
-- `explosive-rocket` and `atomic-bomb` all share that category, so all three load straight
-- from the bus with NO ammo item of our own and no repack recipe -- and each keeps its own
-- vanilla payload, so we inherit three balanced warheads for free. (Confirmed working in
-- the playtest-4 feasibility test: the turret accepts them, fires them, the rocket
-- projectile renders correctly, and damage/explosion swap per missile type.)
--
-- ZERO NEW ART: the body is the vanilla rocket-silo sprite shrunk 9x9 -> 7x7 and washed
-- red (the same borrowed-and-tinted treatment as prototypes/tech_icon.lua); the barrel is
-- the vanilla artillery cannon scaled to sit on it.
--
-- ONE PER SURFACE PER FORCE -- enforced in scripts/build_guard.lua, not here; no prototype
-- field expresses it.

local util = require("util")
local tech_icon = require("prototypes.tech_icon")

local SILO_S = 7 / 9              -- silo body 9x9 -> 7x7 (a DOWNscale, so it stays crisp)
local CANNON_S = 7 / 3 * 0.45     -- barrel sized to sit on the larger base
local TINT = { r = 1, g = 0.45, b = 0.45, a = 1 }

local RANGE = 528          -- 96..528 tiles (playtest 4: +4 chunks on the original 400)
local MIN_RANGE = 96
local SLOTS = 8            -- mixable ammo slots
local PER_SLOT = 8         -- rounds each slot holds (capped by the item's own stack size)

-- Mirrors the helper in mini_artillery.lua. Kept separate rather than shared: the two
-- files scale different art in different directions and unifying them buys nothing.
local function scale_sprite(t, s, tint)
  if type(t) ~= "table" then return end
  if type(t.scale) == "number" then t.scale = t.scale * s end
  if tint and t.filename then t.tint = tint end
  local sh = t.shift
  if type(sh) == "table" then
    if sh.x then
      t.shift = { x = sh.x * s, y = sh.y * s }
    elseif sh[1] then
      t.shift = { sh[1] * s, sh[2] * s }
    end
  end
  if t.layers then
    for _, l in pairs(t.layers) do scale_sprite(l, s, tint) end
  end
end

-- 1. Gun: an artillery mount that eats vanilla rocket ammo -------------------------------
local cannon = util.table.deepcopy(data.raw["gun"]["artillery-wagon-cannon"])
cannon.name = "territorio-missile-battery-cannon"
cannon.attack_parameters.ammo_category = "rocket"
cannon.attack_parameters.range = RANGE
cannon.attack_parameters.min_range = MIN_RANGE
-- 0.1 s between shells, so a salvo pours out in well under a second. The real rate limiter
-- is shots_per_flare on the flare below, not this.
cannon.attack_parameters.cooldown = 6
data:extend({ cannon })

-- 2. Salvo flare + its own remote --------------------------------------------------------
--
-- `artillery-flare.shots_per_flare` is the rate limiter: vanilla is 1, so one designation
-- is one shell however short the cooldown. This one stays at 1 TOO -- the salvo is eight
-- separate flares, not one flare worth eight shots. scripts/missile_battery.lua rings the
-- click with seven more on use.
--
-- WHY, having shipped it the other way first (playtest 4 -> 5):
--   * shots_per_flare = 8 put all eight missiles on the same tile. Eight warheads in one
--     crater is mostly wasted; a nest is an area, so the salvo should cover an area.
--   * one flare draws ONE targeting flag, so the map gave no sign that eight were inbound.
--     Eight flares draw eight flags using the flare's own vanilla sprite -- the readout the
--     salvo needed, at zero art cost.
--   * the shared-budget trap is unchanged but degrades better. That number was never
--     per-turret: it is a budget for the flare shared by EVERY artillery turret in range
--     (flares carry no category, turrets no filter), so a Mortar nearby ate the battery's
--     salvo -- 1 missile fired with Mortars up, 8 with them gone. Split across eight
--     flares a Mortar now takes whole flares instead of gutting one salvo, but it still
--     takes them: the battery SUPERSEDES the Mortar. Retire in-base Mortars once it is up.
--
-- Both remotes stay useful and mean different things: the vanilla artillery remote is a
-- single precision shot, this one is the spread salvo.
local flare = util.table.deepcopy(data.raw["artillery-flare"]["artillery-flare"])
flare.name = "territorio-missile-flare"
flare.shots_per_flare = 1
data:extend({ flare })

local remote = util.table.deepcopy(data.raw["capsule"]["artillery-targeting-remote"])
remote.name = "territorio-missile-remote"
remote.capsule_action = { type = "artillery-remote", flare = "territorio-missile-flare" }
remote.order = "b[turret]-d[territorio-missile-battery]-b[remote]"
data:extend({ remote })

-- 3. Entity -------------------------------------------------------------------------------
local turret = util.table.deepcopy(data.raw["artillery-turret"]["artillery-turret"])
turret.name = "territorio-missile-battery"
turret.minable = { mining_time = 2, result = "territorio-missile-battery" }
turret.fast_replaceable_group = "territorio-missile-battery"
turret.max_health = 600
turret.gun = "territorio-missile-battery-cannon"
turret.disable_automatic_firing = true    -- designated targets only, never auto-acquire
turret.manual_range_modifier = 1

-- THE COST OF A SPREAD SALVO, and the fix for it (playtest 5). One flare worth eight shots
-- needed no re-aiming, so the burst poured out at the gun's 6-tick cooldown. Eight separate
-- flares are eight distinct targets, and the turret has to traverse between them -- at which
-- point two INHERITED vanilla numbers dominate the salvo instead of the cooldown:
--   * turn_after_shooting_cooldown = 60 -- a full second of "may not turn" after EVERY
--     shot. Seven of those is a seven-second salvo on its own.
--   * turret_rotation_speed = 0.001 rev/tick, i.e. ~16 s per revolution. Fine for a weapon
--     that re-aims once an hour, far too slow to walk a cluster.
-- Both are tuned for a siege gun that fires one shell at a time. This is a missile battery
-- emptying a magazine at one map square, so it gets rack numbers instead.
turret.turn_after_shooting_cooldown = 0
turret.turret_rotation_speed = 0.01

-- Eight mixable ammo slots. `inventory_size` is the real slot count (vanilla artillery is
-- 1). NOTE the engine consumes the first non-empty slot until it is empty rather than
-- round-robining, so a single salvo is one missile type; scripts/missile_battery.lua
-- rotates the stacks once per salvo so consecutive salvos lead with a different type.
--
-- `automated_ammo_count` is the TOTAL number of rounds an inserter or logistic bot will
-- push in -- not a per-slot figure. At 8 it was satisfied by one full slot, which is why
-- inserters filled slot 1 and stopped and the rest had to be loaded by hand (playtest 5).
-- Deriving it from the whole inventory is the only value that can't drift out of step.
turret.inventory_size = SLOTS
turret.ammo_stack_limit = PER_SLOT
turret.automated_ammo_count = SLOTS * PER_SLOT

turret.collision_box = { { -3.4, -3.4 }, { 3.4, 3.4 } }
turret.selection_box = { { -3.5, -3.5 }, { 3.5, 3.5 } }
turret.drawing_box_vertical_extension = 5

local silo = data.raw["rocket-silo"]["rocket-silo"]
local body = util.table.deepcopy(silo.base_day_sprite)
scale_sprite(body, SILO_S, TINT)
turret.base_picture = body

scale_sprite(turret.cannon_barrel_pictures, CANNON_S)
scale_sprite(turret.cannon_base_pictures, CANNON_S)
turret.water_reflection = nil     -- the borrowed silo body has none to match
if turret.cannon_base_shift then
  turret.cannon_base_shift = {
    (turret.cannon_base_shift[1] or 0) * CANNON_S,
    (turret.cannon_base_shift[2] or 0) * CANNON_S,
    (turret.cannon_base_shift[3] or 0) * CANNON_S,
  }
end
if turret.cannon_barrel_recoil_shiftings then
  for _, r in ipairs(turret.cannon_barrel_recoil_shiftings) do
    r[1], r[2], r[3] = (r[1] or 0) * CANNON_S, (r[2] or 0) * CANNON_S, (r[3] or 0) * CANNON_S
  end
end

data:extend({ turret })

-- 4. Item + recipe -------------------------------------------------------------------------
local item = util.table.deepcopy(data.raw["item"]["artillery-turret"])
item.name = "territorio-missile-battery"
-- Red wash, same as the techs and the Mortar. The deepcopy carries vanilla's flat `icon`,
-- which has to be cleared: `icon` and `icons` on one prototype is a load error.
item.icon = nil
item.icon_size = nil
item.icons = tech_icon("__base__/graphics/icons/artillery-turret.png", 64)
item.place_result = "territorio-missile-battery"
item.order = "b[turret]-d[territorio-missile-battery]"
item.stack_size = 1               -- one per surface anyway; no reason to carry a stack
data:extend({ item })

data:extend({
  {
    type = "recipe",
    name = "territorio-missile-battery",
    enabled = false,
    energy_required = 30,
    ingredients = {
      { type = "item", name = "steel-plate", amount = 200 },
      { type = "item", name = "concrete", amount = 100 },
      { type = "item", name = "advanced-circuit", amount = 50 },
      { type = "item", name = "engine-unit", amount = 40 },
    },
    results = { { type = "item", name = "territorio-missile-battery", amount = 1 } },
  },
})

-- 5. Technology ------------------------------------------------------------------------------
data:extend({
  {
    type = "technology",
    name = "territorio-missile-battery",
    icons = tech_icon("__base__/graphics/technology/rocketry.png"),
    -- chemical-science-pack is named explicitly even though it looks redundant next to
    -- rocketry: vanilla rocketry costs red/green/MILITARY only, so nothing in that chain
    -- guarantees blue. Without this the tech went available the moment rocketry finished
    -- and then stalled the whole research queue on a pack you could not make (playtest 5).
    prerequisites = { "rocketry", "military-science-pack", "chemical-science-pack" },
    effects = {
      { type = "unlock-recipe", recipe = "territorio-missile-battery" },
    },
    unit = {
      count = 400,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "military-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-n1",
  },
})
