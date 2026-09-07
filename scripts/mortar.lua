-- Mortar (mini-artillery) force bonuses.
--
-- A mortar shell IS a grenade -- that's its recipe and its payload -- so vanilla's Stronger
-- Explosives research ought to make it hit harder. It can't on its own: the shell carries
-- its own isolated ammo category ("territorio-mortar-shell", deliberately un-cross-loadable
-- with vanilla artillery), and Stronger Explosives is a VANILLA technology this mod must
-- never edit to add an effect to.
--
-- So the bonus is mirrored at runtime instead: whatever ammo-damage modifier the force
-- currently has for the vanilla "grenade" category is copied onto the mortar's category.
-- Nothing is modified, vanilla or ours -- and it tracks every Stronger Explosives level,
-- including the infinite tail, without hard-coding tech names or per-level numbers.

local MORTAR_CATEGORY = "territorio-mortar-shell"
local SOURCE_CATEGORY = "grenade"

local mortar = {}

--- Copy the force's grenade damage bonus onto the mortar shell's ammo category.
function mortar.sync_force(force)
  if not (force and force.valid) then return end
  local bonus = force.get_ammo_damage_modifier(SOURCE_CATEGORY) or 0
  -- Only write on an actual change: set_* on a force is a global-effect call, and this
  -- runs on every on_research_finished in the game, not just Territorio's own.
  if force.get_ammo_damage_modifier(MORTAR_CATEGORY) ~= bonus then
    force.set_ammo_damage_modifier(MORTAR_CATEGORY, bonus)
  end
end

function mortar.sync_all()
  for _, force in pairs(game.forces) do
    mortar.sync_force(force)
  end
end

return mortar
