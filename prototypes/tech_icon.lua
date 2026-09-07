-- Shared red-wash icon treatment for everything Territorio owns: technologies, and since
-- playtest 5, items too.
--
-- The mod authors zero art, so every one of its prototypes wears a borrowed vanilla icon --
-- which leaves things ambiguous: "Automated Border Wall" is the same picture as vanilla
-- "Stone wall", "Territorial Expansion" the same as "Landfill", and the Mortar and Missile
-- Battery are both literally the artillery turret in the crafting menu and the inventory.
--
-- The fix is a tint, not an image: the borrowed icon is drawn twice, the upper layer
-- washed red. The vanilla silhouette still says what the thing IS, while the colour says
-- it belongs to Territorio -- one family, readable at tech-tree zoom and at 32px in a
-- toolbar. Still zero authored art: `tint` is a config transform on art the game ships.
--
-- Pass the real size: vanilla technology icons are 256, item icons are 64.

local TINT = { r = 1, g = 0.25, b = 0.25, a = 0.55 }

--- Build the `icons` layer list for a Territorio technology or item.
--- @param path string  a vanilla icon path
--- @param size number|nil  icon_size of that file (tech icons 256, item icons 64)
return function(path, size)
  size = size or 256
  return {
    { icon = path, icon_size = size },
    { icon = path, icon_size = size, tint = TINT },
  }
end
