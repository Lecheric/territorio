-- Phase 4-surveillance: pure-research frontier surveillance.
--
-- A tile-locked base can't afford to line its border with vanilla radars (each costs a
-- scarce chunk + UPS, and reveals a radius around its interior, not the frontier). So
-- this is script-only: once `territorio-surveillance` is researched, the map is kept
-- charted in a band N chunks outside the WHOLE territory border -- enough to see
-- encroaching nests and aim artillery strikes at them. `territorio-surveillance-deep`
-- widens the band and adds a "sector pulse": it charges over time, and the widget Scan
-- button spends a charge to chart a big stretch outward from the territory.
--
-- Charting the whole band at once every few seconds strobes (re-charting an already
-- charted chunk plays a reveal shimmer). Instead the maintenance sweep rolls: each tick
-- it re-charts a few chunks, cycling through the band ordered by angle around the
-- territory centre -- a slow rotating arc, like an old sonar screen. `force.chart` only
-- charts (terrain + structures stay visible, dimmed); the engine has no API to hold an
-- area live without a radar entity, and that was the design trade for "no entity".
--
-- Building actual vanilla radars speeds the arc up (they already reveal outward on their
-- own -- this just makes them help the border sweep too): 1 radar = a 60 s revolution,
-- scaling linearly to a 12 s revolution at 20+ radars.
--
-- MULTIPLAYER: the rolling CURSOR lives in storage (`scan_sweep`), not in a module-local.
-- It decides which chunks get charted this tick, and charting is game state -- a client
-- joining mid-revolution would rebuild a module-local cursor from scratch while the host
-- kept its own, chart different chunks on the same tick, and desync. Only the ordered
-- chunk LIST is still module-local, as a pure cache: it is rebuilt deterministically from
-- the owned set (see build_list's total-order sort) and never carries information the
-- cursor doesn't already have.
--
-- All numbers first-pass; expect tuning against a real playthrough.

local util = require("scripts.util")
local state = require("scripts.state")

local surveillance = {}

local CHUNK = util.CHUNK_SIZE
local atan2, floor = math.atan2, math.floor

local BAND_TIER1 = 10       -- chunks of fog kept charted outside the border
local BAND_TIER2 = 16

-- Sweep speed scales with the force's radar count. The full band is re-charted over one
-- revolution of exactly `secs` seconds, spread evenly across the 6 handler calls/second
-- (on_nth_tick(10)), so every revolution is a whole number of ticks -- clean at 60 Hz.
--   <=1 radar  -> SWEEP_SECS_SLOW (60 s)
--   2..19      -> linear between (rounded to whole seconds)
--   >=20       -> SWEEP_SECS_FAST (12 s), the cap
local SWEEP_SECS_SLOW = 60
local SWEEP_SECS_FAST = 12
local RADAR_FULL_SPEED = 20
local CALLS_PER_SEC = 6         -- 60 ticks/s / on_nth_tick(10)

local POINTS_PER_PULSE = 5400   -- ~15 min per pulse charge at 6 calls/s
-- Playtest 5: banking two pulses meant the second was always spent immediately after the
-- first, charting a huge stretch in one go and flattening the map. Capping at 1 makes the
-- pulse a thing you decide WHEN to spend rather than a small stockpile, and idle charge
-- past a full bank is discarded rather than stored.
local MAX_PULSES = 1
local BURST_DEPTH = 15          -- extra chunks the pulse charts beyond the maintained band
-- Prospecting (its own EARLY tech, deliberately not a surveillance tier -- see below).
-- GENERATE is what the mod asks the map to create; PROSPECT is how far it then looks. The
-- two differ because generation costs save size permanently while scanning is free.
local PROSPECT_GENERATE = 12
local PROSPECT_RADIUS = 20

-- Pure derived cache, safe to lose at any moment: [surface_index .. ":" .. force_name] =
-- the angle-ordered band list. The cursor into it lives in storage.territorio.scan_sweep.
local scan_lists = {}

local function sweep_key(surface_index, force_name)
  return surface_index .. ":" .. force_name
end

--- Widest surveillance band this force has unlocked, in chunks (0 = no tech).
function surveillance.band(force)
  local techs = force.technologies
  if not techs then return 0 end
  local deep = techs["territorio-surveillance-deep"]
  if deep and deep.researched then return BAND_TIER2 end
  local base = techs["territorio-surveillance"]
  if base and base.researched then return BAND_TIER1 end
  return 0
end

--- Has this force unlocked resource prospecting?
--- NOTE this is NOT a surveillance tier: it lands before blue science, where neither
--- Frontier Surveillance (chemical) nor the sector pulse (production) exists yet. Its whole
--- job is early -- find the oil before you spend chunk tokens reaching for it.
function surveillance.prospecting(force)
  local t = force.technologies and force.technologies["territorio-prospecting"]
  return t ~= nil and t.researched
end

--- Has this force unlocked the sector pulse (tier 2)?

--- Has this force unlocked the sector pulse (tier 2)?
function surveillance.tier2(force)
  local deep = force.technologies and force.technologies["territorio-surveillance-deep"]
  return deep ~= nil and deep.researched
end

function surveillance.get_charges(force)
  return storage.territorio.scan_charges[force.name] or 0
end

--- Progress toward the next pulse charge as a 0..1 fraction, plus whether the pool is capped.
function surveillance.progress(force)
  local t = storage.territorio
  if (t.scan_charges[force.name] or 0) >= MAX_PULSES then return 1, true end
  return (t.scan_points[force.name] or 0) / POINTS_PER_PULSE, false
end

-- Owned chunk set for a force on a surface, or nil.
local function owned_set(surface_index, force_name)
  local t = storage.territorio
  local by_force = t and t.unlocked_chunks[surface_index]
  return by_force and by_force[force_name]
end

-- Unowned chunk keys within `band` (chebyshev) of any owned chunk.
local function band_keys(owned, band)
  local out = {}
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      for dx = -band, band do
        for dy = -band, band do
          local nk = util.chunk_key(cx + dx, cy + dy)
          if not owned[nk] then out[nk] = true end
        end
      end
    end
  end
  return out
end

local function chart_chunk(force, surface, cx, cy)
  force.chart(surface, { { cx * CHUNK, cy * CHUNK }, { cx * CHUNK + CHUNK, cy * CHUNK + CHUNK } })
end

--- Chart every chunk holding a resource near this force's territory, and ask the map to
--- generate a little more ground to look at next time.
---
--- WHY generation is requested: "already generated" is roughly "already charted" in the
--- early game, so a pure scan would only ever show ore you can already see. Requesting
--- generation is what gives prospecting something to actually find. It is deliberately
--- NON-blocking (`request_to_generate_chunks` without force_generate_chunk_requests), so
--- chunks arrive over the following ticks instead of freezing the game -- which means the
--- first pass sees little and each later pass sees more.
---
--- GENERATE is kept well under PROSPECT because generated chunks live in the save forever:
--- 12 chunks out is ~625 chunks of map, 20 would be ~1700.
function surveillance.prospect(surface_index, force)
  if state.is_ai_force(force.name) then return end
  if not surveillance.prospecting(force) then return end

  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end
  local owned = owned_set(surface_index, force.name)
  if not owned then return end

  local min_x, min_y, max_x, max_y
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      if not min_x or cx < min_x then min_x = cx end
      if not max_x or cx > max_x then max_x = cx end
      if not min_y or cy < min_y then min_y = cy end
      if not max_y or cy > max_y then max_y = cy end
    end
  end
  if not min_x then return end

  -- Ask for more ground, centred on the territory. Already-generated chunks are ignored
  -- cheaply by the engine, so re-requesting every territory change costs nothing.
  local mid_x = (min_x + max_x + 1) * CHUNK / 2
  local mid_y = (min_y + max_y + 1) * CHUNK / 2
  local span = math.max(max_x - min_x, max_y - min_y)
  surface.request_to_generate_chunks({ x = mid_x, y = mid_y },
    PROSPECT_GENERATE + math.ceil(span / 2))

  -- Then chart whatever generated ground within reach holds ore. limit = 1: we only care
  -- THAT a chunk has a resource, never how much, so this early-outs on the first hit
  -- rather than walking an entire patch.
  local lo_x, hi_x = min_x - PROSPECT_RADIUS, max_x + PROSPECT_RADIUS
  local lo_y, hi_y = min_y - PROSPECT_RADIUS, max_y + PROSPECT_RADIUS
  for chunk in surface.get_chunks() do
    if chunk.x >= lo_x and chunk.x <= hi_x and chunk.y >= lo_y and chunk.y <= hi_y then
      local n = surface.count_entities_filtered({
        area = {
          { chunk.x * CHUNK, chunk.y * CHUNK },
          { chunk.x * CHUNK + CHUNK, chunk.y * CHUNK + CHUNK },
        },
        type = "resource",
        limit = 1,
      })
      if n > 0 then chart_chunk(force, surface, chunk.x, chunk.y) end
    end
  end
end

--- Prospect every surface this force holds territory on.
function surveillance.prospect_force(force)
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then surveillance.prospect(surface_index, force) end
  end
end

--- One-shot: chart the entire current band for a force on a surface. Bulk is fine here --
--- it runs on a single event (research / load), not on a repeating timer.
function surveillance.reveal_now(surface_index, force)
  if state.is_ai_force(force.name) then return end
  local band = surveillance.band(force)
  if band == 0 then return end
  local owned = owned_set(surface_index, force.name)
  if not owned then return end
  local surface = game.get_surface(surface_index)
  if not surface or not state.is_managed_surface(surface) then return end
  for key in pairs(band_keys(owned, band)) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then chart_chunk(force, surface, cx, cy) end
  end
end

--- Territory changed (chunk bought / dev unlock): re-reveal the band now and drop the
--- cached sweep list so it rebuilds against the new border on the next tick.
function surveillance.on_territory_changed(surface_index, force)
  local sk = sweep_key(surface_index, force.name)
  scan_lists[sk] = nil
  -- Drop the cursor too: it indexes a list that no longer describes this border. Every
  -- peer runs this same handler, so they all restart the revolution together.
  local t = storage.territorio
  if t and t.scan_sweep then t.scan_sweep[sk] = nil end
  surveillance.reveal_now(surface_index, force)
  -- Prospecting rides territory changes rather than a timer: bounded to player actions,
  -- and claiming ground is exactly when "what is out there?" matters.
  surveillance.prospect(surface_index, force)
end

function surveillance.reveal_now_force(force)
  if state.is_ai_force(force.name) then return end
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    if by_force[force.name] then surveillance.reveal_now(surface_index, force) end
  end
end

function surveillance.reveal_now_all()
  local t = storage.territorio
  if not t then return end
  for surface_index, by_force in pairs(t.unlocked_chunks) do
    for force_name in pairs(by_force) do
      local force = game.forces[force_name]
      if force and force.valid then surveillance.reveal_now(surface_index, force) end
    end
  end
end

-- Build the angle-ordered band list for one force/surface (rotating-arc sweep order).
local function build_list(surface_index, force)
  local owned = owned_set(surface_index, force.name)
  local band = surveillance.band(force)
  if not owned or band == 0 then return nil end

  local sum_x, sum_y, n = 0, 0, 0
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then sum_x, sum_y, n = sum_x + cx + 0.5, sum_y + cy + 0.5, n + 1 end
  end
  if n == 0 then return nil end
  local ccx, ccy = sum_x / n, sum_y / n

  local list = {}
  for key in pairs(band_keys(owned, band)) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      list[#list + 1] = { cx = cx, cy = cy, a = atan2(cy + 0.5 - ccy, cx + 0.5 - ccx) }
    end
  end
  -- TOTAL order, not just "sorted by angle": two band chunks can share an angle exactly,
  -- and table.sort is unstable, so a tie would resolve according to the pairs() insertion
  -- order above -- which is NOT guaranteed to match between a host that built the owned
  -- set incrementally and a client that deserialised it. Breaking ties on (cx, cy) makes
  -- the result independent of iteration order, so every peer rebuilds the same list.
  table.sort(list, function(p, q)
    if p.a ~= q.a then return p.a < q.a end
    if p.cx ~= q.cx then return p.cx < q.cx end
    return p.cy < q.cy
  end)
  return list
end

-- The band list for one force/surface, rebuilt on demand. Losing this cache is harmless:
-- the cursor that says WHERE in the revolution we are lives in storage.
local function get_list(surface_index, force)
  local sk = sweep_key(surface_index, force.name)
  local list = scan_lists[sk]
  if not list then
    list = build_list(surface_index, force)
    scan_lists[sk] = list
  end
  return list
end

--- Rolling maintenance sweep + pulse-charge accrual. control.lua: on_nth_tick(10).
function surveillance.on_tick()
  local t = storage.territorio
  -- scan_sweep is seeded by state.ensure_root, which a HOT-RELOAD does not run (no
  -- on_configuration_changed). Bail rather than index a nil table.
  if not (t and t.scan_sweep) then return end

  for surface_index, by_force in pairs(t.unlocked_chunks) do
    local surface = game.get_surface(surface_index)
    if surface and state.is_managed_surface(surface) then
      for force_name in pairs(by_force) do
        local force = game.forces[force_name]
        if force and force.valid and not state.is_ai_force(force_name)
            and surveillance.band(force) > 0 then

          local sk = sweep_key(surface_index, force_name)
          local list = get_list(surface_index, force)
          local st = t.scan_sweep[sk]

          -- Start a revolution when there is no cursor, when the last one finished, or
          -- when the list length no longer matches what the cursor was measured against
          -- (a stale cursor could index past the end of a shrunken list).
          if list and #list > 0
              and (not st or st.cursor > st.len or st.len ~= #list) then
            -- More force radars on the surface = a faster border sweep, capped at the old
            -- fixed speed. Recounted once per revolution, not once per tick.
            st = {
              cursor = 1,
              len = #list,
              accum = 0,
              radars = surface.count_entities_filtered({ name = "radar", force = force }),
            }
            t.scan_sweep[sk] = st
          elseif not list or #list == 0 then
            st = nil
            t.scan_sweep[sk] = nil
          end

          if st and st.len > 0 then
            -- Spread the whole list across exactly `secs * CALLS_PER_SEC` handler calls,
            -- so one revolution takes `secs` seconds regardless of how many chunks the
            -- band holds. `accum` carries the sub-chunk-per-call remainder.
            local r = math.min(RADAR_FULL_SPEED, math.max(1, st.radars))
            local secs = floor(SWEEP_SECS_SLOW
              - (r - 1) * (SWEEP_SECS_SLOW - SWEEP_SECS_FAST) / (RADAR_FULL_SPEED - 1) + 0.5)
            st.accum = (st.accum or 0) + st.len / (secs * CALLS_PER_SEC)
            local n = floor(st.accum)
            if n > 0 then
              st.accum = st.accum - n
              local last = math.min(st.cursor + n - 1, st.len)
              for i = st.cursor, last do
                local c = list[i]
                if c then chart_chunk(force, surface, c.cx, c.cy) end
              end
              st.cursor = last + 1
            end
          end

          if surveillance.tier2(force) then
            local charges = t.scan_charges[force_name] or 0
            if charges < MAX_PULSES then
              local pool = (t.scan_points[force_name] or 0) + 1
              if pool >= POINTS_PER_PULSE then
                pool, charges = pool - POINTS_PER_PULSE, charges + 1
                if charges >= MAX_PULSES then pool = 0 end
                force.print({ "territorio-message.scan-ready", charges })
              end
              t.scan_points[force_name] = pool
              t.scan_charges[force_name] = charges
            end
          end
        end
      end
    end
  end
end

--- Spend a pulse charge: chart a large area outward from the force's territory on the
--- player's current surface. Returns true, or false + a reason key.
function surveillance.burst(player)
  local force = player.force
  if not surveillance.tier2(force) then return false, "territorio-message.scan-locked" end

  local t = storage.territorio
  local charges = t.scan_charges[force.name] or 0
  if charges < 1 then return false, "territorio-message.no-scan" end

  local surface = player.surface
  local owned = owned_set(surface.index, force.name)
  if not owned then return false, "territorio-message.no-scan" end

  local min_x, min_y, max_x, max_y
  for key in pairs(owned) do
    local cx, cy = util.parse_chunk_key(key)
    if cx then
      if not min_x or cx < min_x then min_x = cx end
      if not max_x or cx > max_x then max_x = cx end
      if not min_y or cy < min_y then min_y = cy end
      if not max_y or cy > max_y then max_y = cy end
    end
  end
  if not min_x then return false, "territorio-message.no-scan" end

  t.scan_charges[force.name] = charges - 1

  local d = surveillance.band(force) + BURST_DEPTH
  force.chart(surface, {
    { (min_x - d) * CHUNK, (min_y - d) * CHUNK },
    { (max_x + 1 + d) * CHUNK, (max_y + 1 + d) * CHUNK },
  })

  return true
end

return surveillance
