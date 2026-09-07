-- Hidden selection-tools used purely as map-view cursors. Never craftable, never in
-- inventory (only-in-cursor), no recipe. The player gets one by clicking a widget button /
-- shortcut; it is removed when they put it away. `mode = "nothing"` -> selects no
-- entities/tiles, we only want the selected area.
--
-- No authored art: both reuse the engine's spawn-flag marker sprite.

local function map_tool(name, color)
  return {
    type = "selection-tool",
    name = name,
    icon = "__core__/graphics/spawn-flag.png",
    icon_size = 64,
    flags = { "not-stackable", "spawnable", "only-in-cursor" },
    hidden = true,
    subgroup = "other",
    order = "z[territorio]",
    stack_size = 1,
    draw_label_for_cursor_render = true,
    select = { border_color = color, cursor_box_type = "copy", mode = { "nothing" } },
    alt_select = { border_color = color, cursor_box_type = "copy", mode = { "nothing" } },
  }
end

data:extend({
  map_tool("territorio-expansion-tool", { 0, 1, 0 }),
  map_tool("territorio-strike-tool", { 1, 0.5, 0 }),
  map_tool("territorio-synthesize-tool", { 0.6, 0.4, 0.1 }),
  map_tool("territorio-refund-tool", { 1, 0.2, 0.2 }),
})
