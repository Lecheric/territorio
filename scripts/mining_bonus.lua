-- Reward for mining your own ground.
--
-- The far-reach incompatibility was dropped on purpose (v0.1.16): if a player wants to
-- reach past the border and hand-mine, that is not something to punish. This is the other
-- half of that decision -- never punish the unwanted behaviour, reward the correct one.
-- Hand-mining anything INSIDE your own territory is faster; reaching outside it just gets
-- the ordinary vanilla rate, not a penalty.
--
-- No research gate and no prototype: it is a flat, always-available property of owning the
-- ground you stand on.
--
-- Implementation note: mining speed can only be modified per-character, not per-target, so
-- the modifier is toggled based on what the player is currently mining -- `mining_state`
-- for "am I mining", `player.selected` for "what at" -- re-evaluated on the same short
-- interval the boundary uses. 0.1 s of latency is nothing against a mining action measured
-- in whole seconds.
--
-- Compatibility caveat: `character_mining_speed_modifier` is one shared value, so another
-- mod writing it for the same character would fight with this. Nothing in the API scopes
-- it per-source; if that ever bites, the fallback is to drop this feature rather than to
-- try to arbitrate.

local state = require("scripts.state")
local util = require("scripts.util")

local BONUS = 1.0  -- +100% hand-mining speed on your own land. First-pass.

local mining_bonus = {}

--- Is this mining action pointed at ground the player's force owns?
--- Second return is a short reason string, for the diagnostic overlay only.
local function mining_at_home(player)
  local ms = player.mining_state
  -- Not mining: nothing to judge, so keep the bonus rather than silently taking it away.
  if not (ms and ms.mining) then return true, "idle" end

  -- `mining_state.position` is NOT usable here: for player-driven mining the engine hands
  -- back {0,0} whatever the real target is (v0.1.30 probe -- every target resolved to
  -- chunk 0,0, which happens to be starting territory, so the bonus never switched off).
  -- The entity under the cursor IS the one being mined -- you cannot mine something you
  -- are not hovering -- so that is the honest source of the target position.
  local target = player.selected
  if not (target and target.valid) then return true, "no-target" end

  local surface = target.surface
  if not (surface and surface.valid) then return true, "no-surface" end
  -- Off-Nauvis there is no territory to be inside of yet (see state.is_managed_surface) --
  -- don't hand out a penalty for a rule that isn't being enforced there.
  if not state.is_managed_surface(surface) then return true, "unmanaged" end

  local cx, cy = util.pos_to_chunk(target.position)
  return state.is_unlocked(surface.index, player.force.name, cx, cy), cx .. "," .. cy
end

-- DIAGNOSTIC (temporary, /territorio-mining-debug). The bonus reported no in/out
-- difference in playtest; rather than guess which half is wrong, show what the engine
-- actually reports. Reads the modifier back from BOTH the LuaPlayer and the character
-- entity, because vanilla's own PvP scenario writes it on the PLAYER (player[name] =
-- modifier) while this module writes it on the character -- if those are not the same
-- value, that alone is the bug.
local function draw_probe(player, char, reason, want)
  local ok_p, player_mod = pcall(function() return player.character_mining_speed_modifier end)
  local ok_c, char_mod = pcall(function() return char.character_mining_speed_modifier end)
  rendering.draw_text({
    text = string.format(
      "%s | want %.2f | player %s | char %s",
      reason,
      want,
      ok_p and string.format("%.2f", player_mod or -1) or "ERR",
      ok_c and string.format("%.2f", char_mod or -1) or "ERR"),
    surface = char.surface,
    target = { entity = char, offset = { 0, -3 } },
    color = { r = 1, g = 0.9, b = 0.3 },
    scale = 1.2,
    alignment = "center",
    players = { player },
    time_to_live = 8,  -- one poll interval (6) plus slack, so it never stacks up
  })
end

--- Toggle the diagnostic overlay. Returns the new state.
function mining_bonus.toggle_debug()
  local t = storage.territorio
  t.mining_debug = not t.mining_debug
  return t.mining_debug
end

--- Re-evaluate every connected player's hand-mining modifier. connected_players is
--- normally 1-2; the body is a couple of table lookups and an early-out write.
function mining_bonus.on_nth_tick()
  local debug = storage.territorio and storage.territorio.mining_debug
  for _, player in pairs(game.connected_players) do
    local char = player.character
    if char and char.valid then
      local at_home, reason = mining_at_home(player)
      local want = at_home and BONUS or 0
      if char.character_mining_speed_modifier ~= want then
        char.character_mining_speed_modifier = want
      end
      if debug then draw_probe(player, char, reason, want) end
    end
  end
end

return mining_bonus
