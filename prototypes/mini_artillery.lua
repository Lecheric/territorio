-- Phase 4c: the Mortar (internally "mini-artillery").
--
-- NAMING: the player-facing name is "Mortar" / "Mortar shell", set in locale only. Every
-- prototype name stays `territorio-mini-artillery*` on purpose -- renaming a prototype
-- resets research and orphans placed entities and inventory items in existing saves, and
-- the display name is the only part that ever needed to change.
--
-- A shrunk vanilla artillery turret: 2x2, grenade-payload shells, short range, and
-- REMOTE-DESIGNATED FIRE ONLY. The early-game answer to nests that creep near the border,
-- before the mid-game artillery Strike. Full vanilla artillery (yellow science, auto-fire,
-- long range) stays a clean upgrade / replacement.
--
-- Zero authored art: every graphic is the vanilla artillery-turret / artillery-wagon-cannon
-- / artillery-projectile art, deep-copied from data.raw and scaled by 2/3 (a config
-- transform, not new pixels).
--
-- Remote-only: `disable_automatic_firing = true` -- it never auto-acquires, only fires at
-- targets designated with the artillery remote. Range band is 24 (min) to 192 tiles.
--
-- All combat numbers first-pass.

local util = require("util")
local tech_icon = require("prototypes.tech_icon")

local S = 2 / 3  -- visual scale: the 3x3 artillery turret rendered as a 2x2 "mini"

-- Recursively scale `scale` and `shift` on a sprite-shaped table (and its .layers).
local function scale_sprite(t, s)
  if type(t) ~= "table" then return end
  if type(t.scale) == "number" then t.scale = t.scale * s end
  local sh = t.shift
  if type(sh) == "table" then
    if sh.x then
      t.shift = { x = sh.x * s, y = sh.y * s }
    elseif sh[1] then
      t.shift = { sh[1] * s, sh[2] * s }
    end
  end
  if t.layers then
    for _, l in pairs(t.layers) do scale_sprite(l, s) end
  end
end

-- 1. Isolated ammo category (the mini and vanilla artillery can't cross-load) ----------
data:extend({
  { type = "ammo-category", name = "territorio-mortar-shell" },
})

-- 2. Projectile: vanilla artillery arc + reveal_map, grenade-cluster-tier payload -------
local projectile = util.table.deepcopy(data.raw["artillery-projectile"]["artillery-projectile"])
projectile.name = "territorio-mortar-projectile"
-- Payload matched to a VANILLA GRENADE (playtest 4): the shell is a repacked grenade, so
-- it should hit like one. Vanilla `grenade` is an area of radius 6.5 dealing 35 explosion
-- damage and spawning `grenade-explosion` -- copied exactly, replacing the old
-- 2.5-radius / 30 physical + 30 explosion / big-explosion payload. The wider radius is the
-- real change: 2.5 barely covered one biter.
projectile.action = {
  type = "direct",
  action_delivery = {
    type = "instant",
    target_effects = {
      {
        type = "nested-result",
        action = {
          type = "area",
          radius = 6.5,
          action_delivery = {
            type = "instant",
            target_effects = {
              { type = "damage", damage = { amount = 35, type = "explosion" } },
            },
          },
        },
      },
      { type = "create-entity", entity_name = "grenade-explosion" },
      { type = "show-explosion-on-chart", scale = 6 / 32 },
    },
  },
}
data:extend({ projectile })

-- 3. Gun: mortar range band 24-192 tiles -------------------------------------------
local cannon = util.table.deepcopy(data.raw["gun"]["artillery-wagon-cannon"])
cannon.name = "territorio-mini-artillery-cannon"
cannon.attack_parameters.ammo_category = "territorio-mortar-shell"
cannon.attack_parameters.range = 192
cannon.attack_parameters.min_range = 24
cannon.attack_parameters.cooldown = 240
data:extend({ cannon })

-- 4. Ammo item ---------------------------------------------------------------------
data:extend({
  {
    type = "ammo",
    name = "territorio-mini-shell",
    -- Red-washed, same treatment as the techs: otherwise this is pixel-identical to a
    -- vanilla artillery shell in the inventory and the crafting menu, and they are NOT
    -- interchangeable (different ammo category).
    icons = tech_icon("__base__/graphics/icons/artillery-shell.png", 64),
    ammo_category = "territorio-mortar-shell",
    ammo_type = {
      target_type = "position",
      action = {
        type = "direct",
        action_delivery = {
          type = "artillery",
          projectile = "territorio-mortar-projectile",
          -- Slower than an artillery shell (was 1) so the round reads as a lobbed grenade
          -- rather than a cannon shot. Grenades use a different motion model entirely
          -- (thrown, with acceleration), so this is the closest an artillery projectile
          -- gets -- it cannot be matched exactly.
          starting_speed = 0.5,
          direction_deviation = 0,
          range_deviation = 0,
          source_effects = {
            type = "create-explosion",
            entity_name = "artillery-cannon-muzzle-flash",
          },
        },
      },
    },
    subgroup = "ammo",
    order = "d[cannon-shell]-e[territorio-mini]",
    stack_size = 50,
  },
})

-- 5. Entity: deep-copied artillery turret -- 2x2, scaled art, remote-only --------------
local turret = util.table.deepcopy(data.raw["artillery-turret"]["artillery-turret"])
turret.name = "territorio-mini-artillery"
turret.minable = { mining_time = 0.5, result = "territorio-mini-artillery" }
turret.fast_replaceable_group = "territorio-mini-artillery"
turret.max_health = 400
turret.collision_box = { { -0.9, -0.9 }, { 0.9, 0.9 } }
turret.selection_box = { { -1, -1 }, { 1, 1 } }
turret.gun = "territorio-mini-artillery-cannon"
turret.disable_automatic_firing = true  -- remote-designated targets only, never auto-acquire
turret.manual_range_modifier = 1
turret.automated_ammo_count = 50
turret.ammo_stack_limit = 50
turret.turret_rotation_speed = (turret.turret_rotation_speed or 0.001) * 1.5
turret.drawing_box_vertical_extension = (turret.drawing_box_vertical_extension or 3.5) * S

scale_sprite(turret.base_picture, S)
scale_sprite(turret.cannon_barrel_pictures, S)
scale_sprite(turret.cannon_base_pictures, S)
if turret.water_reflection and turret.water_reflection.pictures then
  scale_sprite(turret.water_reflection.pictures, S)
end
if turret.cannon_base_shift then
  turret.cannon_base_shift = {
    (turret.cannon_base_shift[1] or 0) * S,
    (turret.cannon_base_shift[2] or 0) * S,
    (turret.cannon_base_shift[3] or 0) * S,
  }
end
if turret.cannon_barrel_recoil_shiftings then
  for _, r in ipairs(turret.cannon_barrel_recoil_shiftings) do
    r[1], r[2], r[3] = (r[1] or 0) * S, (r[2] or 0) * S, (r[3] or 0) * S
  end
end

data:extend({ turret })

-- 6. Turret item -----------------------------------------------------------------
local turret_item = util.table.deepcopy(data.raw["item"]["artillery-turret"])
turret_item.name = "territorio-mini-artillery"
-- Same red wash as the shell and the techs. The deepcopy carries vanilla's flat `icon`,
-- which has to be cleared: `icon` and `icons` on one prototype is a load error.
turret_item.icon = nil
turret_item.icon_size = nil
turret_item.icons = tech_icon("__base__/graphics/icons/artillery-turret.png", 64)
turret_item.place_result = "territorio-mini-artillery"
turret_item.order = "b[turret]-c[territorio-mini-artillery]"
turret_item.stack_size = 10
data:extend({ turret_item })

-- 7. Recipes (unlocked by the tech) --------------------------------------------------
data:extend({
  {
    type = "recipe",
    name = "territorio-mini-shell",
    enabled = false,
    energy_required = 4,
    ingredients = {
      { type = "item", name = "grenade", amount = 1 },
      { type = "item", name = "steel-plate", amount = 1 },
    },
    results = { { type = "item", name = "territorio-mini-shell", amount = 1 } },
  },
  {
    type = "recipe",
    name = "territorio-mini-artillery",
    enabled = false,
    energy_required = 8,
    ingredients = {
      { type = "item", name = "steel-plate", amount = 20 },
      { type = "item", name = "iron-gear-wheel", amount = 30 },
      { type = "item", name = "electronic-circuit", amount = 20 },
      { type = "item", name = "gun-turret", amount = 2 },
    },
    results = { { type = "item", name = "territorio-mini-artillery", amount = 1 } },
  },
})

-- 8. Technology -- early (red+green), gated on grenades + walls ----------------------
data:extend({
  {
    type = "technology",
    name = "territorio-mini-artillery",
    icons = tech_icon("__base__/graphics/technology/artillery.png"),
    prerequisites = { "military-2", "stone-wall" },
    effects = {
      { type = "unlock-recipe", recipe = "territorio-mini-artillery" },
      { type = "unlock-recipe", recipe = "territorio-mini-shell" },
    },
    unit = {
      count = 100,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-m1",
  },
})
