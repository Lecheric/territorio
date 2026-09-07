-- All Territorio GUI + the map-view tools.
--
--   * a small draggable widget (top-right, near the minimap), a vertical stack of:
--       "Expansion tool (N)" -- N = tokens; arm it, box-select chunks in map view to claim
--       "Strike (N)" + bar   -- N = banked artillery-strike charges; arm, click the map
--       "Missile salvo"      -- hands you the salvo remote (once the Missile Battery is
--                               researched); not a mode, just the item in your cursor
--       "Scan (N)" + bar     -- surveillance sector pulse (shown once Deep-Range researched)
--       "Synthesize" + picker -- Ore Generator (shown once Resource Synthesis researched):
--                               toggles a resource picker; picking arms a map-select tool
--   * arming a tool = clearing the cursor and putting the hidden selection-tool in it.
--     Expansion, Refund and Synthesize each turn on their own chunk overlay
--     (scripts/overlay.lua) -- green "1" to buy, red "+1" to sell, amber "2" with the ore
--     field's footprint to synthesize. Strike does not; it is a single click, not an area.
--   * putting a tool away (right-click / Q / clicking its button again) disarms.
--
-- Purchase: scripts/purchase.lua. Strike: strikes.lua. Ore Generator: resource_gen.lua.

local state = require("scripts.state")
local tokens = require("scripts.tokens")
local adjacency = require("scripts.adjacency")
local overlay = require("scripts.overlay")
local purchase = require("scripts.purchase")
local strikes = require("scripts.strikes")
local walls = require("scripts.walls")
local surveillance = require("scripts.surveillance")
local resource_gen = require("scripts.resource_gen")
local beautify = require("scripts.beautify")
local border_paint = require("scripts.border_paint")
local perimeter_defense = require("scripts.perimeter_defense")
local refund = require("scripts.refund")
local missile_battery = require("scripts.missile_battery")

local gui = {}

local WIDGET = "territorio-widget"
local EXPANSION_TOOL = "territorio-expansion-tool"
local STRIKE_TOOL = "territorio-strike-tool"
local SYNTH_TOOL = "territorio-synthesize-tool"
local REFUND_TOOL = "territorio-refund-tool"
local SHORTCUT = "territorio-expansion"
-- Not a selection tool: the salvo remote is a real capsule item, and the button just puts
-- it in your hand. It lived only in the shortcut bar before, which nobody found -- the two
-- remotes look identical there, and the vanilla one fires a single missile.
local SALVO_REMOTE = missile_battery.REMOTE

-- Picker sprite per synthesizable resource.
local SYNTH_SPRITES = {
  ["iron-ore"] = "item/iron-ore", ["copper-ore"] = "item/copper-ore",
  ["stone"] = "item/stone", ["coal"] = "item/coal",
  ["crude-oil"] = "fluid/crude-oil", ["uranium-ore"] = "item/uranium-ore",
}

-- territorio-resource-synthesis is a REPEATABLE tech: LuaTechnology.researched reflects
-- whether the CURRENT level pointer is done, which flips back to false the moment a level
-- completes and the pointer auto-advances to the next un-researched level (only staying
-- true once capped at max_level). So "is the feature unlocked at all" must go through
-- resource_gen.level's proper completed-level reading, not a raw .researched check.
local function synth_unlocked(force)
  return resource_gen.level(force) >= 1
end

local function synth_caption(player)
  return { "territorio-gui.synth", resource_gen.level(player.force) }
end

-- ---- widget -------------------------------------------------------------------------

local function expansion_caption(player)
  return { "territorio-gui.tool", tokens.get(player.force) }
end

local function expansion_tooltip(player)
  return { "territorio-gui.expansion-tooltip",
    state.chunk_count(player.surface.index, player.force.name) }
end

local function strike_caption(player)
  return { "territorio-gui.strike", strikes.get_charges(player.force) }
end

local function scan_caption(player)
  return { "territorio-gui.scan", surveillance.get_charges(player.force) }
end

local function armed_tool(player)
  local cs = player.cursor_stack
  return cs and cs.valid_for_read and cs.name or nil
end

function gui.reposition(player)
  local frame = player.gui.screen[WIDGET]
  if not frame then return end
  local saved = storage.territorio.gui_location[player.index]
  if saved then
    frame.location = saved
  else
    local res, scale = player.display_resolution, player.display_scale
    frame.location = { x = res.width - math.floor(360 * scale), y = math.floor(10 * scale) }
  end
end

function gui.build(player)
  local existing = player.gui.screen[WIDGET]
  if existing then existing.destroy() end
  local stale = player.gui.top["territorio-token-counter"]
  if stale then stale.destroy() end

  local frame = player.gui.screen.add({ type = "frame", name = WIDGET })
  frame.style.padding = 4

  -- Vertical stack: grip / Expansion button / Strike button / progress bar. Everything
  -- stretches to the widest child so the bar lines up under the Strike button.
  local flow = frame.add({ type = "flow", name = "flow", direction = "vertical" })
  flow.style.vertical_spacing = 3
  flow.drag_target = frame

  local grip = flow.add({ type = "empty-widget", name = "grip", style = "draggable_space" })
  grip.style.height = 8
  grip.style.horizontally_stretchable = true
  grip.drag_target = frame

  local expansion = flow.add({
    type = "button", name = "expansion", caption = expansion_caption(player),
    tooltip = expansion_tooltip(player),
    tags = { territorio_action = "expansion" },
  })
  expansion.style.horizontally_stretchable = true

  local strike = flow.add({
    type = "button", name = "strike", caption = strike_caption(player),
    tags = { territorio_action = "strike" },
  })
  strike.style.horizontally_stretchable = true

  local bar = flow.add({ type = "progressbar", name = "strikebar" })
  bar.style.horizontally_stretchable = true
  bar.style.height = 6

  -- Missile salvo -- hidden until territorio-missile-battery. Sits with Strike because it
  -- is the same kind of decision: pick a spot on the map and hurt it.
  local salvo = flow.add({
    type = "button", name = "salvo", caption = { "territorio-gui.salvo" },
    tooltip = { "territorio-gui.salvo-tooltip" },
    tags = { territorio_action = "salvo" },
  })
  salvo.style.horizontally_stretchable = true

  -- Sector-pulse (Deep-Range Surveillance) -- hidden until researched. Not a cursor tool:
  -- the pulse is radial, so the button fires it straight away.
  local scan = flow.add({
    type = "button", name = "scan", caption = scan_caption(player),
    tags = { territorio_action = "scan" },
  })
  scan.style.horizontally_stretchable = true

  local scanbar = flow.add({ type = "progressbar", name = "scanbar" })
  scanbar.style.horizontally_stretchable = true
  scanbar.style.height = 6

  -- Ore Generator -- hidden until territorio-resource-synthesis. The button toggles a
  -- resource picker; picking one arms the synthesize tool for a map selection.
  local synth = flow.add({
    type = "button", name = "synth", caption = synth_caption(player),
    tooltip = { "territorio-gui.synth-tooltip" },
    tags = { territorio_action = "synth" },
  })
  synth.style.horizontally_stretchable = true

  local picker = flow.add({ type = "flow", name = "synthpicker", direction = "horizontal" })
  picker.visible = false
  picker.style.horizontal_spacing = 2
  for _, res in ipairs(resource_gen.RESOURCES) do
    local b = picker.add({
      type = "sprite-button", name = "synthpick-" .. res, sprite = SYNTH_SPRITES[res],
      tags = { territorio_action = "synth-pick", resource = res },
    })
    b.style.size = 32
  end

  -- Chunk refund -- hidden until territorio-chunk-refund. Arms a map-select tool like the
  -- Expansion tool, but sells the selection back instead of buying it.
  local refundb = flow.add({
    type = "button", name = "refund", caption = { "territorio-gui.refund" },
    tooltip = { "territorio-gui.refund-tooltip" },
    tags = { territorio_action = "refund" },
  })
  refundb.style.horizontally_stretchable = true

  gui.reposition(player)
  gui.sync(player)
end

-- Push current state into the widget buttons + the shortcut.
function gui.sync(player)
  local frame = player.gui.screen[WIDGET]
  local flow = frame and frame.flow
  if not (flow and flow.expansion and flow.strike and flow.strikebar and flow.salvo
      and flow.scan and flow.scanbar and flow.synth and flow.synthpicker
      and flow.refund) then return end

  flow.expansion.caption = expansion_caption(player)
  flow.expansion.tooltip = expansion_tooltip(player)
  flow.expansion.toggled = state.expansion_mode(player)

  local unlocked = strikes.unlocked(player.force)
  flow.strike.caption = strike_caption(player)
  flow.strike.enabled = unlocked
  flow.strike.toggled = armed_tool(player) == STRIKE_TOOL
  flow.strike.tooltip = unlocked and { "territorio-gui.strike-tooltip" } or { "territorio-gui.strike-locked" }
  flow.strikebar.value = strikes.progress(player.force)

  local salvo_ready = missile_battery.unlocked(player.force)
  flow.salvo.visible = salvo_ready
  if salvo_ready then
    flow.salvo.toggled = armed_tool(player) == SALVO_REMOTE
  end

  local scan_ready = surveillance.tier2(player.force)
  flow.scan.visible = scan_ready
  flow.scanbar.visible = scan_ready
  if scan_ready then
    flow.scan.caption = scan_caption(player)
    flow.scan.enabled = surveillance.get_charges(player.force) > 0
    flow.scan.tooltip = { "territorio-gui.scan-tooltip" }
    flow.scanbar.value = select(1, surveillance.progress(player.force))
  end

  local synth_ready = synth_unlocked(player.force)
  flow.synth.visible = synth_ready
  flow.synth.toggled = armed_tool(player) == SYNTH_TOOL
  if synth_ready then
    flow.synth.caption = synth_caption(player)
    local level = resource_gen.level(player.force)
    for _, res in ipairs(resource_gen.RESOURCES) do
      local b = flow.synthpicker["synthpick-" .. res]
      local need = resource_gen.unlock_level(res)
      local unlocked = level >= need
      b.enabled = unlocked
      b.tooltip = unlocked
        and { "territorio-gui.synth-pick", { "?", { "item-name." .. res }, { "fluid-name." .. res }, res } }
        or { "territorio-gui.synth-pick-locked",
          { "?", { "item-name." .. res }, { "fluid-name." .. res }, res }, need }
    end
  else
    flow.synthpicker.visible = false
  end

  local refund_ready = refund.unlocked(player.force)
  flow.refund.visible = refund_ready
  if refund_ready then
    flow.refund.toggled = armed_tool(player) == REFUND_TOOL
    flow.refund.tooltip = { "territorio-gui.refund-tooltip", refund.tier(player.force) }
  end

  if player.is_shortcut_available(SHORTCUT) then
    player.set_shortcut_toggled(SHORTCUT, state.expansion_mode(player))
  end
end

local function widget_current(frame)
  return frame and frame.flow and frame.flow.expansion
    and frame.flow.strike and frame.flow.strikebar and frame.flow.salvo
    and frame.flow.scan and frame.flow.scanbar
    and frame.flow.synth and frame.flow.synthpicker
    and frame.flow.refund
end

function gui.refresh(player)
  -- Rebuild if the widget is missing OR has an older structure (changed between versions);
  -- gui.build destroys the stale one first.
  if widget_current(player.gui.screen[WIDGET]) then
    gui.sync(player)
  else
    gui.build(player)
  end
end

-- Slow refresh so the strike progress bar tracks kills between explicit refreshes.
function gui.on_tick()
  for _, player in pairs(game.connected_players) do
    gui.refresh(player)
  end
end

function gui.refresh_force(force)
  for _, player in pairs(force.connected_players) do gui.refresh(player) end
end

function gui.refresh_all()
  for _, player in pairs(game.connected_players) do gui.refresh(player) end
end

-- ---- arm / disarm ------------------------------------------------------------------

local function give_tool(player, tool_name)
  local cs = player.cursor_stack
  if not cs then return false end
  if cs.valid_for_read and cs.name == tool_name then return true end
  if not player.clear_cursor() then return false end -- returns the held item to inventory
  return cs.set_stack({ name = tool_name })
end

function gui.arm_expansion(player)
  if give_tool(player, EXPANSION_TOOL) then
    state.set_expansion_mode(player, true)
    gui.sync(player)
    overlay.redraw()
  end
end

function gui.arm_strike(player)
  if give_tool(player, STRIKE_TOOL) then
    gui.sync(player)
  end
end

-- The salvo remote is a real capsule item, not one of the hidden selection tools, so
-- "arming" it just hands the player a spare -- there is no mode to enter and no overlay.
-- Same surface expression scripts/missile_battery.lua uses, so the button never offers a
-- salvo the capsule handler would then ignore.
function gui.arm_salvo(player)
  local surface = player.physical_surface or player.surface
  if not missile_battery.present(surface, player.force) then
    player.create_local_flying_text({
      text = { "territorio-message.no-battery" }, position = player.physical_position,
    })
    return
  end
  if give_tool(player, SALVO_REMOTE) then
    gui.sync(player)
  end
end

function gui.arm_refund(player)
  if give_tool(player, REFUND_TOOL) then
    state.set_refund_mode(player, true)
    gui.sync(player)
    overlay.redraw()
  end
end

function gui.arm_synth(player, resource)
  storage.territorio.synth_resource[player.index] = resource
  if give_tool(player, SYNTH_TOOL) then
    local frame = player.gui.screen[WIDGET]
    if frame and frame.flow and frame.flow.synthpicker then frame.flow.synthpicker.visible = false end
    state.set_synth_mode(player, true)
    gui.sync(player)
    overlay.redraw()
  end
end

-- Shortcut-bar entry point (toggles the Expansion tool specifically).
function gui.toggle(player)
  if state.expansion_mode(player) then gui.disarm(player, true) else gui.arm_expansion(player) end
end

-- Clears the expansion overlay when the expansion tool is no longer in the cursor. `hard`
-- also empties the cursor (button/shortcut press); state is set first so the resulting
-- on_player_cursor_stack_changed is a no-op.
function gui.disarm(player, hard)
  state.set_expansion_mode(player, false)
  state.set_refund_mode(player, false)
  state.set_synth_mode(player, false)
  if hard then
    local cs = player.cursor_stack
    if cs and cs.valid_for_read
        and (cs.name == EXPANSION_TOOL or cs.name == STRIKE_TOOL or cs.name == SYNTH_TOOL
          or cs.name == REFUND_TOOL or cs.name == SALVO_REMOTE) then
      cs.clear()
    end
  end
  gui.sync(player)
  overlay.redraw()
end

-- ---- events -----------------------------------------------------------------------

function gui.on_gui_click(event)
  local el = event.element
  local action = el and el.valid and el.tags and el.tags.territorio_action
  if not action then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  if action == "expansion" then
    if state.expansion_mode(player) then gui.disarm(player, true) else gui.arm_expansion(player) end
  elseif action == "strike" then
    if armed_tool(player) == STRIKE_TOOL then gui.disarm(player, true) else gui.arm_strike(player) end
  elseif action == "salvo" then
    if armed_tool(player) == SALVO_REMOTE then gui.disarm(player, true) else gui.arm_salvo(player) end
  elseif action == "scan" then
    local ok, reason = surveillance.burst(player)
    if ok then
      gui.refresh_force(player.force)
    else
      player.create_local_flying_text({ text = { reason }, position = player.physical_position })
    end
  elseif action == "synth" then
    if armed_tool(player) == SYNTH_TOOL then
      gui.disarm(player, true)
    else
      local picker = el.parent and el.parent.synthpicker
      if picker then picker.visible = not picker.visible end
    end
  elseif action == "synth-pick" then
    gui.arm_synth(player, el.tags.resource)
  elseif action == "refund" then
    if armed_tool(player) == REFUND_TOOL then gui.disarm(player, true) else gui.arm_refund(player) end
  end
end

function gui.on_gui_location_changed(event)
  local el = event.element
  if el and el.valid and el.name == WIDGET then
    storage.territorio.gui_location[event.player_index] = el.location
  end
end

function gui.on_cursor_stack_changed(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  -- Any of the three overlays must drop the moment its own tool leaves the cursor.
  local tool = armed_tool(player)
  if (state.expansion_mode(player) and tool ~= EXPANSION_TOOL)
      or (state.refund_mode(player) and tool ~= REFUND_TOOL)
      or (state.synth_mode(player) and tool ~= SYNTH_TOOL) then
    gui.disarm(player, false)
  else
    gui.sync(player)
  end
end

-- ---- tool selections -------------------------------------------------------------

local function chunks_in_area(area)
  local lt, rb = area.left_top, area.right_bottom
  local cx0, cy0 = math.floor(lt.x / 32), math.floor(lt.y / 32)
  local cx1 = math.max(cx0, math.ceil(rb.x / 32) - 1)
  local cy1 = math.max(cy0, math.ceil(rb.y / 32) - 1)
  local out = {}
  for cx = cx0, cx1 do
    for cy = cy0, cy1 do
      out[#out + 1] = { cx, cy }
    end
  end
  return out
end

local function area_center(area)
  return {
    x = (area.left_top.x + area.right_bottom.x) / 2,
    y = (area.left_top.y + area.right_bottom.y) / 2,
  }
end

local function flash_reject(player, cx, cy)
  rendering.draw_rectangle({
    color = { r = 1, g = 0.2, b = 0.2, a = 0.9 }, filled = false, width = 3,
    left_top = { x = cx * 32, y = cy * 32 },
    right_bottom = { x = cx * 32 + 32, y = cy * 32 + 32 },
    surface = player.surface, players = { player }, time_to_live = 45,
  })
end

local function do_expansion_select(player, event)
  local force, surface_index = player.force, player.surface.index
  local list = chunks_in_area(event.area)
  local center = area_center(event.area)

  local bought = 0
  for _, c in pairs(list) do
    if tokens.get(force) < 1 then break end
    if adjacency.can_purchase(surface_index, force, c[1], c[2]) and purchase.execute(player, c[1], c[2]) then
      bought = bought + 1
    end
  end

  if bought > 0 then
    overlay.redraw()
    walls.refresh(surface_index, force)
    surveillance.on_territory_changed(surface_index, force)
    beautify.apply(surface_index, force)
    border_paint.refresh(surface_index, force)   -- after beautify, always
    perimeter_defense.on_territory_changed(surface_index, force)
    gui.refresh_force(force)
    player.create_local_flying_text({ text = { "territorio-message.claimed", bought }, position = center })
  elseif #list == 1 then
    flash_reject(player, list[1][1], list[1][2])
    local reason = tokens.get(force) < 1 and "territorio-message.no-tokens" or "territorio-message.cant-expand-here"
    player.create_local_flying_text({ text = { reason }, position = center })
  end
end

local function do_refund_select(player, event)
  local force, surface_index = player.force, player.surface.index
  local center = area_center(event.area)

  local sold, reason = refund.execute(player, chunks_in_area(event.area))
  if sold > 0 then
    -- Same post-territory-change fan-out the purchase path runs: the border moved inward,
    -- so the wall ring, surveillance band and perimeter defences all have to follow it.
    overlay.redraw()
    walls.refresh(surface_index, force)
    surveillance.on_territory_changed(surface_index, force)
    perimeter_defense.on_territory_changed(surface_index, force)
    -- The border moved INWARD, so the hazard band has to be lifted off the ground that is
    -- no longer ours and re-laid on the new edge.
    border_paint.refresh(surface_index, force)
    gui.refresh_force(force)
    player.create_local_flying_text({ text = { "territorio-message.refunded", sold }, position = center })
  else
    player.create_local_flying_text({ text = { reason }, position = center })
  end
end

local function do_strike_select(player, event)
  local center = area_center(event.area)
  local ok, reason = strikes.call_strike(player, center)
  if ok then
    gui.refresh_force(player.force)
  else
    player.create_local_flying_text({ text = { reason }, position = center })
  end
end

function gui.on_selected_area(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  if event.item == EXPANSION_TOOL then
    do_expansion_select(player, event)
  elseif event.item == STRIKE_TOOL then
    do_strike_select(player, event)
  elseif event.item == SYNTH_TOOL then
    resource_gen.on_select(player, event)
    gui.refresh_force(player.force)
  elseif event.item == REFUND_TOOL then
    do_refund_select(player, event)
  end
end

return gui
