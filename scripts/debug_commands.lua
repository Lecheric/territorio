-- Dev-only console commands, kept for testing (the Expansion tool is the shipped way in).
--
--   /territorio-unlock [x y]   grant the caller's force a chunk on the current surface
--   /territorio-lock   [x y]   take it back
--
-- With no argument the chunk is the one at the caller's position -- which in Remote View is
-- the camera, so you can pan anywhere and unlock it. With `x y` it is that chunk directly,
-- which works from anywhere. Not exposed to players; handy for setting up valve tests.

local util = require("scripts.util")
local overlay = require("scripts.overlay")
local walls = require("scripts.walls")
local surveillance = require("scripts.surveillance")
local beautify = require("scripts.beautify")
local perimeter_defense = require("scripts.perimeter_defense")
local mining_bonus = require("scripts.mining_bonus")

local debug_commands = {}

local function target_chunk(player, parameter)
  if parameter and parameter ~= "" then
    local sx, sy = parameter:match("^%s*(-?%d+)%s+(-?%d+)%s*$")
    if sx then
      return tonumber(sx), tonumber(sy)
    end
    player.print("[territorio] expected: /territorio-unlock [<chunk_x> <chunk_y>]")
    return nil
  end
  return util.pos_to_chunk(player.position)
end

local function set_chunk(command, unlocked)
  local player = game.get_player(command.player_index)
  if not player then return end

  local cx, cy = target_chunk(player, command.parameter)
  if not cx then return end

  local t = storage.territorio
  local si = player.surface.index
  local force_name = player.force.name
  t.unlocked_chunks[si] = t.unlocked_chunks[si] or {}
  t.unlocked_chunks[si][force_name] = t.unlocked_chunks[si][force_name] or {}
  t.unlocked_chunks[si][force_name][util.chunk_key(cx, cy)] = unlocked or nil

  overlay.redraw()
  walls.refresh(si, player.force)
  surveillance.on_territory_changed(si, player.force)
  beautify.apply(si, player.force)
  perimeter_defense.on_territory_changed(si, player.force)
  player.print(string.format("[territorio] %s: chunk %d,%d -> %s",
    player.surface.name, cx, cy, unlocked and "unlocked" or "locked"))
end

function debug_commands.unlock(command)
  set_chunk(command, true)
end

function debug_commands.lock(command)
  set_chunk(command, false)
end

-- TEMPORARY diagnostic for the in-territory hand-mining bonus (v0.1.30). Draws a live
-- readout over your character every poll: what mining_state reports, what modifier the
-- module wants, and what the modifier reads back as from the player AND from the
-- character entity. Remove once the bonus is confirmed working.
function debug_commands.mining_debug(command)
  local player = game.get_player(command.player_index)
  if not player then return end
  local on = mining_bonus.toggle_debug()
  player.print("[territorio] mining probe " .. (on and "ON" or "OFF")
    .. " -- readout: <mining_state> | want <n> | player <n> | char <n>")
end

return debug_commands
