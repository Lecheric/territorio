-- Shared chunk / position math.
--
-- The Factorio API is authoritative for chunk geometry: chunks are a fixed 32-tile grid
-- aligned to the map origin, so the chunk of a position is floor(coord / 32). We keep
-- this in one place so the boundary check and the overlay agree on the grid.

local util = {}

local floor = math.floor
local CHUNK_SIZE = 32

util.CHUNK_SIZE = CHUNK_SIZE

--- Chunk coordinates containing a map position.
-- @param pos MapPosition ({x=, y=})
-- @return number cx, number cy
function util.pos_to_chunk(pos)
  return floor(pos.x / CHUNK_SIZE), floor(pos.y / CHUNK_SIZE)
end

--- Stable string key for a chunk, used as the inner table key in storage.
function util.chunk_key(cx, cy)
  return cx .. "," .. cy
end

--- Inverse of chunk_key. Returns nil if the string is not a chunk key.
function util.parse_chunk_key(key)
  local sx, sy = key:match("^(-?%d+),(-?%d+)$")
  if not sx then return nil end
  return tonumber(sx), tonumber(sy)
end

return util
