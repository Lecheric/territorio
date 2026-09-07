-- Mod settings. Startup only, and there is exactly one.
--
-- Playtest 5: ten levels per expansion tech is too long a tail. Rather than cutting it to
-- five for everybody, the level cap becomes the difficulty dial, because it is the honest
-- one: every level past the first is +1 token, so capping levels caps how much of the map
-- you can ever own. That is the mod's entire difficulty axis in one number.
--
-- STARTUP, not runtime, because max_level is a prototype field. Prototypes are read once
-- when the game loads, so this cannot be changed from an in-game dialog or mid-save.
-- prototypes/technologies.lua reads it.
--
-- A string setting rather than an int one purely so the options can be NAMED: int settings
-- with allowed_values render as bare numbers, string settings get a [string-mod-setting]
-- locale entry each.
--
-- Deliberately NOT per-tier: five separate caps would be five ways to build an incoherent
-- tech tree, and the interesting choice is "how much map do I get", not "how much map do I
-- get out of green specifically".

data:extend({
  {
    type = "string-setting",
    name = "territorio-expansion-levels",
    setting_type = "startup",
    default_value = "medium",
    allowed_values = { "easy", "medium", "hard" },
    order = "a",
  },
})
