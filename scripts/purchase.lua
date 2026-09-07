-- Executing a chunk purchase. Pure logic -- callers (scripts/gui.lua) redraw the overlay
-- and refresh the counter afterwards (so a bulk drag-buy redraws once, not per chunk).

local util = require("scripts.util")
local tokens = require("scripts.tokens")
local adjacency = require("scripts.adjacency")
local refund = require("scripts.refund")

local purchase = {}

--- Claim (cx, cy) for the player's force. Returns ok(boolean), reason_key(string|nil).
-- Re-validates everything -- by the time this runs a teammate may have taken the chunk or
-- spent the tokens.
function purchase.execute(player, cx, cy)
  local force = player.force
  local surface = player.surface
  local surface_index = surface.index

  if not adjacency.can_purchase(surface_index, force, cx, cy) then
    return false, "territorio-message.cant-expand-here"
  end
  if not tokens.spend(force, 1) then
    return false, "territorio-message.no-tokens"
  end

  local t = storage.territorio
  t.unlocked_chunks[surface_index] = t.unlocked_chunks[surface_index] or {}
  t.unlocked_chunks[surface_index][force.name] = t.unlocked_chunks[surface_index][force.name] or {}
  t.unlocked_chunks[surface_index][force.name][util.chunk_key(cx, cy)] = true

  -- Re-chart the claimed chunk (already generated) plus its 3x3 neighbourhood, so the new
  -- purchasable ring is always charted -- expansion can never soft-lock ("always-creep").
  force.chart(surface, { { (cx - 1) * 32, (cy - 1) * 32 }, { (cx + 2) * 32, (cy + 2) * 32 } })

  -- If this chunk was mothballed by a refund, its machines were deactivated. Buying it
  -- back is what wakes them -- no mothball registry to keep in sync, the chunk itself is
  -- the record.
  refund.on_chunk_reclaimed(surface, force, cx, cy)

  return true
end

return purchase
