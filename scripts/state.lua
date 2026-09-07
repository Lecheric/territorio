-- storage.territorio: the mod's entire persistent state.
--
-- Shape (multi-surface-aware from day one so per-planet rules can be added later without
-- re-keying; only Nauvis is seeded for now):
--
--   storage.territorio = {
--     unlocked_chunks = { [surface_index] = { [force_name] = { ["x,y"] = true } } },
--     tokens          = { [force_name] = <int> },
--     last_valid_pos  = { [player_index] = { x =, y = } },
--     awarded_levels  = { [force_name] = { [tech_name] = <int> } },
--     expansion_mode  = { [player_index] = true },   -- expansion tool armed / overlay on
--     refund_mode     = { [player_index] = true },   -- refund tool armed / overlay on
--     gui_location    = { [player_index] = { x =, y = } },  -- dragged widget position
--     strike_points   = { [force_name] = <int> },     -- kill points toward the next charge
--     strike_charges  = { [force_name] = <int> },     -- banked artillery-strike charges
--     border_walls    = { [surface_index] = { [force_name] = { ["tx,ty"] = LuaEntity } } },
--                                                     -- stone-walls scripts/walls.lua placed
--     wall_suppressed = { [surface_index] = { [force_name] = { ["tx,ty"] = true } } },
--                                                     -- perimeter tiles the player hand-mined
--     scan_points     = { [force_name] = <int> },     -- sweeps toward the next sector pulse
--     scan_charges    = { [force_name] = <int> },     -- banked surveillance sector pulses
--     scan_sweep      = { ["si:force"] = { cursor =, len =, accum =, radars = } },
--                                        -- surveillance rolling-arc position. MUST be here
--                                        -- and not module-local: it decides which chunks
--                                        -- get charted, and charting is game state, so a
--                                        -- joining client rebuilding it from scratch while
--                                        -- the host keeps its cursor is a desync.
--     overlay_dirty   = <bool>,          -- overlay redraw pending; same reasoning
--     synth_resource  = { [player_index] = "iron-ore" },  -- transient: Ore Generator pick
--     perimeter_teeth          = { [surface_index] = { [force_name] = { ["tx,ty"] = LuaEntity } } },
--     perimeter_teeth_suppressed = { [surface_index] = { [force_name] = { ["tx,ty"] = true } } },
--     perimeter_mines          = { [surface_index] = { [force_name] = { ["tx,ty"] = LuaEntity } } },
--     perimeter_mines_suppressed = { [surface_index] = { [force_name] = { ["tx,ty"] = true } } },
--                                                     -- scripts/perimeter_defense.lua's placements
--   }
--
-- Tokens and territory are keyed per force (not per player): a force researches together,
-- and this leaves team-based expansion racing possible later without a re-key.

local util = require("scripts.util")

local state = {}

-- Seed geometry: a 2x2 block whose shared corner is the map origin, where the player
-- spawns. 10 free tokens on top, spent from the map view via the Expansion tool.
local SEED_CHUNKS = { { -1, -1 }, { 0, -1 }, { -1, 0 }, { 0, 0 } }
local STARTING_TOKENS = 10

-- The AI forces never move or build through our events; seeding them would just be noise.
local SKIP_FORCES = { enemy = true, neutral = true }

local function ensure_root()
  storage.territorio = storage.territorio or {}
  local t = storage.territorio
  t.unlocked_chunks = t.unlocked_chunks or {}
  t.tokens = t.tokens or {}
  t.last_valid_pos = t.last_valid_pos or {}
  -- awarded_levels[force_name][tech_name] = highest expansion-tech level already paid out,
  -- so on_research_finished never double-awards.
  t.awarded_levels = t.awarded_levels or {}
  t.expansion_mode = t.expansion_mode or {}
  t.refund_mode = t.refund_mode or {}
  t.synth_mode = t.synth_mode or {}
  t.gui_location = t.gui_location or {}
  t.strike_points = t.strike_points or {}
  t.strike_charges = t.strike_charges or {}
  t.border_walls = t.border_walls or {}
  t.wall_suppressed = t.wall_suppressed or {}
  -- border_paint[surface_index][force_name]["tx,ty"] = the tile name that was there before
  -- the hazard band went down, so the band can be lifted cleanly when the border moves.
  t.border_paint = t.border_paint or {}
  t.scan_points = t.scan_points or {}
  t.scan_charges = t.scan_charges or {}
  t.scan_sweep = t.scan_sweep or {}
  if t.overlay_dirty == nil then t.overlay_dirty = false end
  t.synth_resource = t.synth_resource or {}
  t.perimeter_teeth = t.perimeter_teeth or {}
  t.perimeter_teeth_suppressed = t.perimeter_teeth_suppressed or {}
  t.perimeter_mines = t.perimeter_mines or {}
  t.perimeter_mines_suppressed = t.perimeter_mines_suppressed or {}
  return t
end

-- Give a force its starting territory + tokens on Nauvis, once. Idempotent: an existing
-- territory set for that force/surface is left untouched.
local function seed_force(force)
  if SKIP_FORCES[force.name] then return end
  local nauvis = game.surfaces["nauvis"]
  if not nauvis then return end

  local t = ensure_root()
  local si = nauvis.index
  t.unlocked_chunks[si] = t.unlocked_chunks[si] or {}
  if t.unlocked_chunks[si][force.name] then return end

  local set = {}
  for _, c in pairs(SEED_CHUNKS) do
    set[util.chunk_key(c[1], c[2])] = true
  end
  t.unlocked_chunks[si][force.name] = set
  t.tokens[force.name] = t.tokens[force.name] or STARTING_TOKENS
end

function state.on_init()
  ensure_root()
  for _, force in pairs(game.forces) do
    seed_force(force)
  end
end

-- Runs when the mod is added to an existing save, or upgraded: seed any force that
-- predates it.
function state.on_configuration_changed()
  ensure_root()
  for _, force in pairs(game.forces) do
    seed_force(force)
  end
end

function state.on_force_created(event)
  if event.force and event.force.valid then
    seed_force(event.force)
  end
end

--- How many chunks this force owns on this surface.
function state.chunk_count(surface_index, force_name)
  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local set = by_force and by_force[force_name]
  if not set then return 0 end
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

--- Is a chunk owned by this force on this surface?
function state.is_unlocked(surface_index, force_name, cx, cy)
  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local set = by_force and by_force[force_name]
  return set ~= nil and set[util.chunk_key(cx, cy)] == true
end

-- The starting 2x2 is the anchor the refund connectivity check flood-fills from, so it
-- can never be sold. Exposed rather than duplicated in scripts/refund.lua.
state.SEED_CHUNKS = SEED_CHUNKS

--- Is this one of the four starting chunks?
function state.is_seed_chunk(cx, cy)
  for _, c in pairs(SEED_CHUNKS) do
    if c[1] == cx and c[2] == cy then return true end
  end
  return false
end

--- The AI forces, which are never given territory.
function state.is_ai_force(force_name)
  return SKIP_FORCES[force_name] == true
end

--- Surfaces the mod actively confines / builds on. Nauvis only for now; per-planet rules
--- (Space Age) will widen this. Everything else -- space platforms, other planets -- is
--- deliberately left unrestricted so the mod doesn't trap the player off Nauvis.
function state.is_managed_surface(surface)
  return surface ~= nil and surface.valid and surface.name == "nauvis"
end

function state.expansion_mode(player)
  return storage.territorio.expansion_mode[player.index] == true
end

function state.set_expansion_mode(player, on)
  storage.territorio.expansion_mode[player.index] = on and true or nil
end

function state.refund_mode(player)
  return storage.territorio.refund_mode[player.index] == true
end

function state.set_refund_mode(player, on)
  storage.territorio.refund_mode[player.index] = on and true or nil
end

function state.synth_mode(player)
  return storage.territorio.synth_mode[player.index] == true
end

function state.set_synth_mode(player, on)
  storage.territorio.synth_mode[player.index] = on and true or nil
end

function state.any_expansion_mode()
  for _, player in pairs(game.connected_players) do
    if storage.territorio.expansion_mode[player.index] then return true end
  end
  return false
end

--- Centre of the force's owned chunk nearest to `pos` on this surface, or nil if it owns
--- nothing here. Used to walk a stray spidertron back home.
function state.nearest_owned_center(surface_index, force_name, pos)
  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  local set = by_force and by_force[force_name]
  if not set then return nil end

  local half = util.CHUNK_SIZE * 0.5
  local best, best_d
  for key in pairs(set) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      local x = cx * util.CHUNK_SIZE + half
      local y = cy * util.CHUNK_SIZE + half
      local dx, dy = x - pos.x, y - pos.y
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then
        best_d, best = d, { x = x, y = y }
      end
    end
  end
  return best
end

return state
