-- Which chunks a force may currently purchase.
--
-- Rule (locked design): a purchasable chunk is one that is NOT already owned, is
-- NSEW-adjacent (no diagonals) to an owned chunk, and has been charted by that force.
-- Charted-only keeps the black unexplored map non-selectable and mitigates buying a
-- chunk with a biter nest sight-unseen.

local util = require("scripts.util")

local adjacency = {}

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

--- Set of "x,y" chunk keys the force can buy on this surface right now.
function adjacency.purchasable(surface_index, force)
  local result = {}

  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local owned = by_force and by_force[force.name]
  if not owned then return result end

  local surface = game.get_surface(surface_index)
  if not surface then return result end

  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      for _, o in pairs(OFFSETS) do
        local nx, ny = cx + o[1], cy + o[2]
        local nkey = util.chunk_key(nx, ny)
        if not owned[nkey] and not result[nkey]
            and force.is_chunk_charted(surface, { x = nx, y = ny }) then
          result[nkey] = true
        end
      end
    end
  end

  return result
end

--- Can this force buy exactly this chunk right now? (ignores token balance)
function adjacency.can_purchase(surface_index, force, cx, cy)
  return adjacency.purchasable(surface_index, force)[util.chunk_key(cx, cy)] == true
end

return adjacency
