-- The map-view "expansion overlay" toggle. `action = "lua"` -> on_lua_shortcut;
-- `toggleable` so the button shows a pressed state. Zero new art: reuses the engine's
-- own spawn-flag marker sprite.

data:extend({
  {
    type = "shortcut",
    name = "territorio-expansion",
    action = "lua",
    toggleable = true,
    localised_name = { "shortcut.territorio-expansion" },
    icon = "__core__/graphics/spawn-flag.png",
    icon_size = 64,
    small_icon = "__core__/graphics/spawn-flag.png",
    small_icon_size = 64,
    order = "z[territorio]",
  },
  -- The vanilla "give artillery targeting remote" shortcut is locked to the late-game
  -- `artillery` tech and we can't edit it. This is the same free vanilla remote item,
  -- unlocked by the mini-artillery tech instead. (Both shortcuts show once the player
  -- also has vanilla `artillery` -- harmless.)
  {
    type = "shortcut",
    name = "territorio-give-artillery-remote",
    action = "spawn-item",
    localised_name = { "shortcut.territorio-give-artillery-remote" },
    item_to_spawn = "artillery-targeting-remote",
    technology_to_unlock = "territorio-mini-artillery",
    unavailable_until_unlocked = true,
    icon = "__base__/graphics/icons/shortcut-toolbar/mip/artillery-targeting-remote-x56.png",
    icon_size = 56,
    small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/artillery-targeting-remote-x24.png",
    small_icon_size = 24,
    order = "z[territorio]-b",
  },
  -- Salvo remote for the Missile Battery. Same free-remote pattern as above, gated on the
  -- battery tech. Reuses the vanilla artillery-remote toolbar icon (zero new art).
  {
    type = "shortcut",
    name = "territorio-give-missile-remote",
    action = "spawn-item",
    localised_name = { "shortcut.territorio-give-missile-remote" },
    item_to_spawn = "territorio-missile-remote",
    technology_to_unlock = "territorio-missile-battery",
    unavailable_until_unlocked = true,
    icon = "__base__/graphics/icons/shortcut-toolbar/mip/artillery-targeting-remote-x56.png",
    icon_size = 56,
    small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/artillery-targeting-remote-x24.png",
    small_icon_size = 24,
    order = "z[territorio]-c",
  },
})
