-- The boundary: keep the player -- and anything they are driving -- inside owned territory.
--
-- WHY teleport-back and not a collision wall: Factorio has no player-only collision layer.
-- A real invisible wall would require editing the base `character` prototype's collision
-- mask (breaks mod compatibility and the mod's no-prototype rule) or a wall entity that
-- also blocks biters -- which would break the deliberate "biters are unrestricted" design.
--
-- WHY it keys off player.vehicle rather than controller_type: a vehicle driven from Remote
-- View reports controller_type == remote with the driven entity in player.vehicle (physical
-- body stationary elsewhere). Riding it normally reports controller_type == character with
-- the same player.vehicle. So: if there is a player.vehicle, that is the thing to keep in
-- bounds; only when on foot with a physical controller do we govern the character position.
--
-- WHY two triggers: on_player_changed_position gives an instant snap on foot but does not
-- fire while driving (ridden or remote), so enforce is also run from an nth-tick scan.

local util = require("scripts.util")
local state = require("scripts.state")

local boundary = {}

--- Bounce a player, or the vehicle they are driving, back inside owned territory.
function boundary.enforce(player)
  if not (player and player.valid) then return end

  local t = storage.territorio
  if not t then return end

  local vehicle = player.vehicle
  if vehicle and not vehicle.valid then vehicle = nil end

  local subject_pos, subject_surface
  if vehicle then
    subject_pos, subject_surface = vehicle.position, vehicle.surface
  else
    -- On foot. Only the character / god controllers move a body; in Remote View,
    -- spectator or editor the body is parked and there is nothing to bounce.
    local ct = player.controller_type
    if ct ~= defines.controllers.character and ct ~= defines.controllers.god then
      return
    end
    subject_pos, subject_surface = player.position, player.surface
  end

  -- Off Nauvis (space platform / another planet) the mod does not confine -- bailing here
  -- keeps the player from being teleport-trapped on an unmanaged surface.
  if not state.is_managed_surface(subject_surface) then return end

  local surface_index = subject_surface.index
  local force_name = player.force.name
  local cx, cy = util.pos_to_chunk(subject_pos)

  if state.is_unlocked(surface_index, force_name, cx, cy) then
    -- Track the last good spot of whatever is currently controlled, so the bounce below
    -- lands right on the border (a wall-bump) rather than jumping to a chunk centre.
    t.last_valid_pos[player.index] = { x = subject_pos.x, y = subject_pos.y }
    return
  end

  local dest = t.last_valid_pos[player.index]
    or state.nearest_owned_center(surface_index, force_name, subject_pos)
    or player.force.get_spawn_position(subject_surface)

  if vehicle then
    -- Kill momentum first (only cars/locomotives allow writing speed) so a fast vehicle
    -- does not immediately re-cross the line.
    local vt = vehicle.type
    if vt == "car" or vt == "locomotive" then
      vehicle.speed = 0
    end
    vehicle.teleport(dest)
  else
    player.teleport(dest)
  end
end

function boundary.on_player_changed_position(event)
  boundary.enforce(game.get_player(event.player_index))
end

-- on_player_changed_position does not fire while driving (ridden or remote), so re-check
-- every connected player on a short interval. connected_players is normally 1-2 entries.
function boundary.on_nth_tick()
  for _, player in pairs(game.connected_players) do
    boundary.enforce(player)
  end
end

return boundary
