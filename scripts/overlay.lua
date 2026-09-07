-- Territory rendering.
--
--  * For each player, in alt-mode: a thin outline around their OWN force's territory, in
--    that player's own colour (forces have no colour in Factorio; players do). Alt-gated
--    (only_in_alt_mode) so it declutters the normal view and the far-zoom map -- Alt
--    reveals the territory edge the same way it reveals recipe icons / other overlays.
--    The Phase 4b border wall shows the edge on its own once researched.
--  * Per player, while the map-view Expansion overlay is toggled on:
--      - owned chunks: a faint white outline at the chunk edge (a tiled grid = "yours")
--      - purchasable chunks: a bright green outline INSET a few tiles (so neighbouring
--        purchasable chunks read as separate boxes, not one block) + a "1" cost label,
--        so it never looks like one token buys the whole section.
--    Borders only -- no filled rectangles; fills read as far too harsh on the map.
--  * Per player, while the Refund tool is armed: the same shapes in red, and "+1" because
--    you gain the token instead of spending it. Only chunks you may ACTUALLY sell are
--    marked, so the gap between "outlined" and "marked" shows at a glance which ground is
--    a starting chunk or is load-bearing for the rest of the territory.
--
-- Per the Diagnostic Rule this overlay IS the diagnostic for the adjacency/charted logic.
--
-- All render objects are tagged with the mod name; rendering.clear("territorio") wipes
-- exactly ours before each full redraw. redraw() runs on toggle, on territory change,
-- and (debounced) when new chunks are charted while someone has the overlay open.

local util = require("scripts.util")
local state = require("scripts.state")
local adjacency = require("scripts.adjacency")
local refund = require("scripts.refund")
local resource_gen = require("scripts.resource_gen")

local overlay = {}

local CHUNK = util.CHUNK_SIZE

-- Forces have no colour in Factorio -- only players do -- so a force's border is drawn
-- once per member, each in that member's own colour. Solo that is simply your colour; on
-- a team it means the border already reads as "ours" without a legend.
local PERIMETER_ALPHA = 0.5
local PERIMETER_FALLBACK = { r = 0, g = 1, b = 0, a = PERIMETER_ALPHA }

local OWNED_LINE = { r = 1, g = 1, b = 1, a = 0.18 }
local BUY_LINE = { r = 0.35, g = 1, b = 0.35, a = 0.9 }
local BUY_LABEL = { r = 0.6, g = 1, b = 0.6, a = 1 }
-- Refund is the inverse of expansion, so it borrows the same shapes in red: same inset
-- outline, same label position, "+1" because you GAIN the token rather than spend it.
local SELL_LINE = { r = 1, g = 0.35, b = 0.35, a = 0.9 }
local SELL_LABEL = { r = 1, g = 0.6, b = 0.6, a = 1 }
-- Amber, deliberately not green (buy) or red (sell): synthesizing is a third verb, and the
-- three tools must never be confused at a glance on the map.
local SYNTH_LINE = { r = 1, g = 0.8, b = 0.25, a = 0.9 }
local SYNTH_LABEL = { r = 1, g = 0.9, b = 0.5, a = 1 }
local BUY_INSET = 3

local EDGES = {
  { dx = 0,  dy = -1, ax = 0, ay = 0, bx = 1, by = 0 },
  { dx = 1,  dy = 0,  ax = 1, ay = 0, bx = 1, by = 1 },
  { dx = 0,  dy = 1,  ax = 0, ay = 1, bx = 1, by = 1 },
  { dx = -1, dy = 0,  ax = 0, ay = 0, bx = 0, by = 1 },
}

-- Redraw-pending flag. In storage, not a module-local: render objects are part of the
-- saved game state, so a host with a pending redraw and a freshly-joined client without
-- one would build different rendering sets on the same tick.

-- A player's own colour, at the overlay's own alpha. player.color carries whatever alpha
-- the player set, and a fully opaque border reads far heavier than the green it replaces,
-- so only the hue is taken.
local function perimeter_color(player)
  local c = player.color
  if not c then return PERIMETER_FALLBACK end
  return { r = c.r, g = c.g, b = c.b, a = PERIMETER_ALPHA }
end

-- `players` scopes the line to that force's own members. Your territory edge is yours to
-- see: unfiltered, every player is shown every force's borders, which is invisible in a
-- one-force game and an information leak the moment there are two.
local function draw_perimeter(surface, owned, players, color)
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local ox, oy = cx * CHUNK, cy * CHUNK
      for _, e in ipairs(EDGES) do
        if not owned[util.chunk_key(cx + e.dx, cy + e.dy)] then
          rendering.draw_line({
            color = color, width = 3,
            from = { x = ox + e.ax * CHUNK, y = oy + e.ay * CHUNK },
            to = { x = ox + e.bx * CHUNK, y = oy + e.by * CHUNK },
            surface = surface, draw_on_ground = true,
            only_in_alt_mode = true,
            players = players,
          })
        end
      end
    end
  end
end

local function draw_outline(surface, cx, cy, color, width, inset, players)
  local ox, oy = cx * CHUNK, cy * CHUNK
  rendering.draw_rectangle({
    color = color, filled = false, width = width,
    left_top = { x = ox + inset, y = oy + inset },
    right_bottom = { x = ox + CHUNK - inset, y = oy + CHUNK - inset },
    surface = surface, players = players,
  })
end

local function draw_expansion(player)
  local surface = player.surface
  local by_force = storage.territorio.unlocked_chunks[surface.index]
  local owned = by_force and by_force[player.force.name]
  if not owned then return end

  local me = { player }

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then draw_outline(surface, cx, cy, OWNED_LINE, 1, 0, me) end
  end

  for key in pairs(adjacency.purchasable(surface.index, player.force)) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      draw_outline(surface, cx, cy, BUY_LINE, 2, BUY_INSET, me)
      rendering.draw_text({
        text = "1",
        surface = surface,
        target = { x = cx * CHUNK + CHUNK / 2, y = cy * CHUNK + CHUNK / 2 },
        color = BUY_LABEL,
        scale = 3.5,
        alignment = "center",
        vertical_alignment = "middle",
        players = me,
      })
    end
  end
end

-- The refund overlay: every owned chunk faintly outlined, and the ones you may actually
-- sell marked in red. The gap between the two IS the information -- an owned chunk with no
-- red marker is either a starting chunk or the only thing holding the rest of your
-- territory together, and seeing that is better than discovering it via a refusal message.
local function draw_refund(player)
  local surface = player.surface
  local by_force = storage.territorio.unlocked_chunks[surface.index]
  local owned = by_force and by_force[player.force.name]
  if not owned then return end

  local me = { player }

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then draw_outline(surface, cx, cy, OWNED_LINE, 1, 0, me) end
  end

  for key in pairs(refund.refundable(surface.index, player.force)) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      draw_outline(surface, cx, cy, SELL_LINE, 2, BUY_INSET, me)
      rendering.draw_text({
        text = "+1",
        surface = surface,
        target = { x = cx * CHUNK + CHUNK / 2, y = cy * CHUNK + CHUNK / 2 },
        color = SELL_LABEL,
        scale = 3.5,
        alignment = "center",
        vertical_alignment = "middle",
        players = me,
      })
    end
  end
end

-- The Synthesize overlay. Playtest 5 asked for the chunk grid while the tool is armed,
-- because a map click gave no sign of which chunk it landed in or where the ore would go.
--
-- The F4 `show-tile-grid` debug option was the first idea and is NOT scriptable: the
-- runtime API exposes only `LuaGameScript.allow_debug_settings`, which lets a player OPEN
-- the debug menu and cannot set an option (checked against the install's runtime-api.json,
-- 2.1.17). Blueprint grid snapping does not apply either, since this is a selection-tool
-- rather than a blueprint. So it is drawn here, with the same shapes as the other two
-- tools -- and drawing it ourselves is better anyway: the inner box is the ACTUAL field
-- footprint at the researched tier, so you can see the ore's extent before paying for it.
local function draw_synth(player)
  local surface = player.surface
  local by_force = storage.territorio.unlocked_chunks[surface.index]
  local owned = by_force and by_force[player.force.name]
  if not owned then return end

  local me = { player }
  local size = resource_gen.field_size(resource_gen.level(player.force))
  -- Centres the field box in the chunk exactly as resource_gen places the ore.
  local inset = size and (CHUNK - size) / 2 or nil
  local cost = tostring(resource_gen.COST)

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      draw_outline(surface, cx, cy, OWNED_LINE, 1, 0, me)
      if inset then
        draw_outline(surface, cx, cy, SYNTH_LINE, 2, inset, me)
        rendering.draw_text({
          text = cost,
          surface = surface,
          target = { x = cx * CHUNK + CHUNK / 2, y = cy * CHUNK + CHUNK / 2 },
          color = SYNTH_LABEL,
          scale = 3.5,
          alignment = "center",
          vertical_alignment = "middle",
          players = me,
        })
      end
    end
  end
end

function overlay.redraw()
  rendering.clear("territorio")

  local t = storage.territorio
  if not t then return end
  t.overlay_dirty = false

  for surface_index, by_force in pairs(t.unlocked_chunks) do
    local surface = game.get_surface(surface_index)
    if surface then
      for force_name, owned in pairs(by_force) do
        local force = game.forces[force_name]
        if force and force.valid then
          -- One pass per MEMBER rather than one per force, since the colour is the
          -- player's. A force with no members draws nothing, which is also why an empty
          -- player list is never passed to the renderer (it might read as "no filter").
          -- Solo this is exactly the old cost; on a team it is one line set per player.
          for _, player in pairs(force.players) do
            draw_perimeter(surface, owned, { player }, perimeter_color(player))
          end
        end
      end
    end
  end

  for _, player in pairs(game.connected_players) do
    if state.expansion_mode(player) then
      draw_expansion(player)
    elseif state.refund_mode(player) then
      draw_refund(player)
    elseif state.synth_mode(player) then
      draw_synth(player)
    end
  end
end

-- Debounce: charting fires rapidly during radar sweeps.
function overlay.mark_dirty()
  local t = storage.territorio
  if t then t.overlay_dirty = true end
end

function overlay.on_tick()
  local t = storage.territorio
  if t and t.overlay_dirty then overlay.redraw() end
end

return overlay
