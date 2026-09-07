-- Spidertron remote + stray-vehicle sweep.
--
-- The movement boundary (scripts/boundary.lua) governs the player and whatever they are
-- actively driving -- ridden or via Remote View. This file covers what slips past that:
--
--   * on_player_used_spidertron_remote -> a remote MOVE order whose target is not owned:
--     cancel the autopilot of any force spidertron routed at it, and show "Area Locked".
--   * periodic sweep -> a player-force car/tank/spidertron left OUTSIDE owned territory
--     with nobody driving it (e.g. remote-driven out, then released). Spidertrons get an
--     autopilot order home (they path freely); cars/tanks are stopped and teleported to
--     the nearest owned chunk.

local util = require("scripts.util")
local state = require("scripts.state")

local vehicle_guard = {}

local abs = math.abs

-- Is this spidertron currently pointed at, or queued toward, `pos`? (~1 tile tolerance;
-- the remote sets the destination to exactly the clicked position.)
local function heading_to(spider, pos)
  local dest = spider.autopilot_destination
  if dest and abs(dest.x - pos.x) < 1 and abs(dest.y - pos.y) < 1 then
    return true
  end
  for _, q in pairs(spider.autopilot_destinations or {}) do
    if abs(q.x - pos.x) < 1 and abs(q.y - pos.y) < 1 then
      return true
    end
  end
  return false
end

function vehicle_guard.on_player_used_spidertron_remote(event)
  if event.success == false then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  local pos = event.position
  local surface = player.surface
  if not state.is_managed_surface(surface) then return end
  local cx, cy = util.pos_to_chunk(pos)
  if state.is_unlocked(surface.index, player.force.name, cx, cy) then return end

  -- The event does not name the selected spidertrons, so cancel any force spidertron that
  -- was just routed at the blocked position. Clearing the destination also clears the
  -- queue, so a path routed *through* locked land is dropped wholesale -- acceptable v1.
  for _, spider in pairs(surface.find_entities_filtered({ type = "spider-vehicle", force = player.force })) do
    if spider.valid and heading_to(spider, pos) then
      spider.autopilot_destination = nil
    end
  end
  player.create_local_flying_text({ text = { "territorio-message.area-locked" }, position = pos })
end

function vehicle_guard.on_nth_tick()
  local t = storage.territorio
  if not t then return end

  -- Vehicles a connected player is driving belong to boundary.enforce -- skip them here so
  -- the two systems never fight over the same teleport.
  local driven = {}
  for _, p in pairs(game.connected_players) do
    local v = p.vehicle
    if v and v.valid then
      driven[v.unit_number] = true
    end
  end

  for _, surface in pairs(game.surfaces) do
    if state.is_managed_surface(surface) then
      for _, veh in pairs(surface.find_entities_filtered({ type = { "car", "spider-vehicle" } })) do
        if veh.valid and not driven[veh.unit_number] and not state.is_ai_force(veh.force.name) then
          local cx, cy = util.pos_to_chunk(veh.position)
          if not state.is_unlocked(surface.index, veh.force.name, cx, cy) then
            local home = state.nearest_owned_center(surface.index, veh.force.name, veh.position)
            if home then
              if veh.type == "spider-vehicle" then
                veh.autopilot_destination = home
              else
                veh.speed = 0
                veh.teleport(home)
              end
            end
          end
        end
      end
    end
  end
end

return vehicle_guard
