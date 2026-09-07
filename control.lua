-- The single event-registration point for the whole mod.
--
-- Factorio's script.on_init / on_load / on_configuration_changed / on_event / on_nth_tick
-- are singleton slots: a second registration for the same hook from another file silently
-- REPLACES the first. So every scripts/*.lua module exports plain functions only, and this
-- file is the one place that wires them to events and dispatches to every module that cares.

local state = require("scripts.state")
local boundary = require("scripts.boundary")
local build_guard = require("scripts.build_guard")
local vehicle_guard = require("scripts.vehicle_guard")
local research = require("scripts.research")
local overlay = require("scripts.overlay")
local gui = require("scripts.gui")
local strikes = require("scripts.strikes")
local walls = require("scripts.walls")
local surveillance = require("scripts.surveillance")
local beautify = require("scripts.beautify")
local border_paint = require("scripts.border_paint")
local perimeter_defense = require("scripts.perimeter_defense")
local mortar = require("scripts.mortar")
local mining_bonus = require("scripts.mining_bonus")
local missile_battery = require("scripts.missile_battery")
-- scripts.resource_gen registers no events -- it is required by scripts.gui, which
-- dispatches on_player_selected_area to it.
local debug_commands = require("scripts.debug_commands")

local EXPANSION_SHORTCUT = "territorio-expansion"

-- Replace the freeplay "Welcome to Factorio" dialog with the mod's own premise. A player
-- who has never seen Territorio otherwise learns about the boundary by walking into it.
--
-- set_custom_intro_message is the scenario's OWN supported hook: freeplay reads
-- storage.custom_intro_message in place of msg-intro / msg-intro-space-age, so this needs
-- no GUI of ours and no vanilla edit. Guarded because the interface only exists when the
-- freeplay scenario is running (a custom scenario has none). Ordering is safe: base
-- registers the interface at its control-script top level, before any mod's on_init.
local function set_intro_message()
  local freeplay = remote.interfaces["freeplay"]
  if freeplay and freeplay["set_custom_intro_message"] then
    remote.call("freeplay", "set_custom_intro_message", { "territorio-message.intro" })
  end
end

script.on_init(function()
  set_intro_message()
  state.on_init()
  overlay.redraw()
  walls.refresh_all()
  surveillance.reveal_now_all()
  beautify.apply_all()
  border_paint.refresh_all()
  perimeter_defense.refresh_all()
  mortar.sync_all()
end)

script.on_configuration_changed(function()
  state.on_configuration_changed()
  gui.refresh_all()
  overlay.redraw()
  walls.refresh_all()
  surveillance.reveal_now_all()
  beautify.apply_all()
  border_paint.refresh_all()
  perimeter_defense.refresh_all()
  mortar.sync_all()
end)

script.on_event(defines.events.on_force_created, function(event)
  state.on_force_created(event)
  overlay.redraw()
  if event.force and event.force.valid then
    mortar.sync_force(event.force)
    -- A new force is seeded with territory immediately, so it gets its edge band
    -- immediately too -- the band is free from the first tick, not a research reward.
    border_paint.refresh_force(event.force)
  end
end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid and storage.territorio) then return end
  -- Seed the player's last-known-good position so the very first boundary check has a
  -- valid place to bounce back to.
  local p = player.position
  storage.territorio.last_valid_pos[player.index] = { x = p.x, y = p.y }
  gui.build(player)
end)

-- The perimeter render objects carry a baked-in list of the force's players, so anything
-- that changes who is in a force has to rebuild them or the newcomer sees no border.
script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then gui.refresh(player) end
  overlay.redraw()
end)

script.on_event(defines.events.on_player_changed_force, function(event)
  -- last_valid_pos is keyed per PLAYER but only meaningful per force: after a force change
  -- it points at ground the player may no longer own, and boundary.enforce would teleport
  -- them to that same invalid spot every tick -- rubber-banded in place forever. Dropping
  -- it falls the bounce back through nearest_owned_center -> force spawn, which are both
  -- guaranteed valid for the NEW force.
  local player = game.get_player(event.player_index)
  if player and player.valid and storage.territorio then
    storage.territorio.last_valid_pos[player.index] = nil
  end
  overlay.redraw()
end)

-- Shortcut-bar entry point for the Expansion tool (the widget button is the other).
-- gui.toggle arms/disarms and keeps the widget + shortcut + overlay in sync.
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= EXPANSION_SHORTCUT then return end
  local player = game.get_player(event.player_index)
  if player and player.valid then gui.toggle(player) end
end)

-- New chunks charted while someone has the overlay open can change the purchasable set.
script.on_event(defines.events.on_chunk_charted, function()
  if state.any_expansion_mode() then overlay.mark_dirty() end
end)

script.on_nth_tick(20, overlay.on_tick)
script.on_nth_tick(31, gui.on_tick)

-- The Expansion tool: arm/disarm, and buy chunks the tool selects.
script.on_event(defines.events.on_player_selected_area, gui.on_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, gui.on_selected_area)
script.on_event(defines.events.on_player_cursor_stack_changed, gui.on_cursor_stack_changed)
script.on_event(defines.events.on_gui_click, gui.on_gui_click)
script.on_event(defines.events.on_gui_location_changed, gui.on_gui_location_changed)

-- Keep the top-right widget anchored when the player changes resolution / UI scale.
local function reposition(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then gui.reposition(player) end
end
script.on_event(defines.events.on_player_display_resolution_changed, reposition)
script.on_event(defines.events.on_player_display_scale_changed, reposition)

script.on_event(defines.events.on_player_changed_position, boundary.on_player_changed_position)

-- on_player_changed_position does not fire while driving (ridden or from Remote View), so
-- re-check every connected player on a short interval. connected_players is normally 1-2.
-- The hand-mining bonus rides the same interval (one registration -- nth_tick slots are
-- singletons like every other hook): it also only needs to track the current player state.
script.on_nth_tick(6, function(event)
  boundary.on_nth_tick(event)
  mining_bonus.on_nth_tick(event)
end)

-- The Missile Battery salvo remote: chart where it lands, and rotate the battery's ammo
-- so the next salvo leads with a different missile type. Only signal available -- there is
-- no event for a turret firing.
script.on_event(defines.events.on_player_used_capsule, missile_battery.on_player_used_capsule)

-- build_guard runs FIRST and may refund + destroy the entity; missile_battery.on_built
-- re-validates rather than assuming a built entity still exists. Wrapped here rather than
-- called from inside build_guard, so guarding stays guarding and control.lua stays the one
-- place that dispatches an event to more than one module.
script.on_event(defines.events.on_built_entity, function(event)
  build_guard.on_built_entity(event)
  missile_battery.on_built(event)
end)
script.on_event(defines.events.on_robot_built_entity, function(event)
  build_guard.on_robot_built_entity(event)
  missile_battery.on_built(event)
end)

-- Hand-mined / deconstructed border wall, dragon's teeth, or land mine is a deliberate
-- gap -- record the tile so the relevant sweep leaves it open. One registration (event
-- hooks are singleton slots) dispatching to both walls.lua (border wall) and
-- perimeter_defense.lua (teeth + mines); each ignores entities/positions that aren't its
-- own. Filtered to the 3 entity names so most mining never enters either handler.
local PERIMETER_MINED_FILTER = {
  { filter = "name", name = "stone-wall" },
  { filter = "name", name = "land-mine" },
}
local function on_perimeter_mined(event)
  walls.on_mined(event)
  perimeter_defense.on_mined(event)
end
script.on_event(defines.events.on_player_mined_entity, on_perimeter_mined, PERIMETER_MINED_FILTER)
script.on_event(defines.events.on_robot_mined_entity, on_perimeter_mined, PERIMETER_MINED_FILTER)

-- Slow sweep: rebuild border walls biters have broken, fill tiles terrain gen caught up
-- on, and (Perimeter Defense T1) heal damaged walls.
script.on_nth_tick(600, walls.on_nth_tick)

-- Slow sweep: rebuild dragon's-teeth / land-mine gaps, follow territory + tier changes.
script.on_nth_tick(650, perimeter_defense.on_nth_tick)

-- Rolling surveillance sweep: re-chart a few band chunks per call (rotating arc), and
-- accrue sector-pulse charges. Frequent + small so it reads as a sweep, not a strobe.
script.on_nth_tick(10, surveillance.on_tick)

-- Economy: award expansion tokens when a Territorio expansion tech completes a level.
-- Also refresh the widget so the Strike button un-greys the moment a strike tech lands.
script.on_event(defines.events.on_research_finished, function(event)
  research.on_research_finished(event)
  if event.research and event.research.valid then
    gui.refresh_force(event.research.force)
    -- Any research at all can be a Stronger Explosives level -- re-mirror the grenade
    -- damage bonus onto the mortar shell rather than hard-coding that tech's names.
    mortar.sync_force(event.research.force)
    -- Border-wall tech: build the ring immediately rather than waiting for the sweep.
    if event.research.name == "territorio-border-wall" then
      walls.refresh_force(event.research.force)
    end
    -- Surveillance tech: chart the band immediately rather than waiting for the sweep.
    if event.research.name == "territorio-surveillance"
        or event.research.name == "territorio-surveillance-deep" then
      surveillance.reveal_now_force(event.research.force)
    end
    -- Prospecting: run one pass now. It is otherwise driven by territory changes, so
    -- without this nothing would happen until the next chunk purchase.
    if event.research.name == "territorio-prospecting" then
      surveillance.prospect_force(event.research.force)
    end
    -- Beautification tech: pave the territory to the new tier now.
    local rn = event.research.name
    if rn == "territorio-beautification" or rn == "territorio-beautification-2"
        or rn == "territorio-beautification-3" then
      beautify.apply_force(event.research.force)
      -- After beautify, always: the hazard band records what it painted over, so it has
      -- to see the new paving tier rather than the ground beneath it.
      border_paint.refresh_force(event.research.force)
    end
    -- Perimeter Defense tech: build/extend teeth and mines immediately rather than
    -- waiting for the sweep (T1 auto-repair has no immediate action, but the call is
    -- cheap and idempotent either way).
    if rn == "territorio-perimeter-defense" or rn == "territorio-perimeter-defense-teeth"
        or rn == "territorio-perimeter-defense-mines"
        or rn == "territorio-perimeter-defense-dense-mines" then
      perimeter_defense.refresh_force(event.research.force)
    end
  end
end)

-- Phase 4a: enemy kills feed a per-force artillery-strike charge pool. Filtered to the
-- entity types enemies use (turret also catches player turrets -- strikes.lua rejects
-- non-"enemy" force), keeping the bulk of entity deaths out of the handler.
script.on_event(defines.events.on_entity_died, function(event)
  local force = strikes.on_entity_died(event)
  if force then gui.refresh_force(force) end
end, {
  { filter = "type", type = "unit" },
  { filter = "type", type = "turret" },
  { filter = "type", type = "unit-spawner" },
})

-- Spidertron remote order gate, plus a slower sweep for any driverless car/tank/spidertron
-- left outside owned territory.
script.on_event(defines.events.on_player_used_spidertron_remote, vehicle_guard.on_player_used_spidertron_remote)
script.on_nth_tick(180, vehicle_guard.on_nth_tick)

-- Dev-only: manual chunk unlock/lock until the Phase 3 purchase UI exists.
commands.add_command("territorio-unlock", "Territorio (dev): unlock a chunk for your force", debug_commands.unlock)
commands.add_command("territorio-lock", "Territorio (dev): lock a chunk for your force", debug_commands.lock)
-- TEMPORARY (v0.1.30): live probe for the in-territory hand-mining bonus.
commands.add_command("territorio-mining-debug", "Territorio (dev): toggle the hand-mining probe", debug_commands.mining_debug)
