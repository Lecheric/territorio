-- Awards expansion tokens when a Territorio expansion technology completes a level.
--
-- Only Territorio's own techs are handled -- every other research in the game is ignored.
-- Token grant per completed level: `first` for level 1 (the milestone bump that makes room
-- for the next science), `rest` for each repeat level after that. First-pass numbers.

local tokens = require("scripts.tokens")
local gui = require("scripts.gui")

local research = {}

-- The 5 expansion techs are the real economy. The others are deliberate one-time
-- allowances so a valve is usable the moment you unlock it -- e.g. Resource Synthesis
-- gives a small token buffer to actually synthesize a patch (level-1 only, no "rest").
--
-- Balance pass (playtest-4): `rest` is a flat 1 on every tier. The *milestone* (level 1)
-- grant is what should move the base forward when a new science tier comes online; levels
-- 2+ are a slow trickle at a rising science cost, not a second economy. That took the
-- ceiling from 247 to 112 -- the Ore Generator (2 tokens/chunk) is meant to compete for
-- that pool.
--
-- Playtest 5 made the ceiling a SETTING (settings.lua, "Territory limit"), because the
-- level cap is the only number that changes how much map exists for you. The fixed part is
-- 51 (milestones) + 10 starting + 6 synthesis = 67; each extra level is +1 per tier, so:
--   Easy   (10 levels) = 67 + 45 = 112 tokens, the playtest-4 economy
--   Medium ( 5 levels) = 67 + 20 =  87 tokens, the new default
--   Hard   ( 3 levels) = 67 + 10 =  77 tokens
-- For scale: playtest 5 reached a launched rocket on 63 chunks.
local GRANTS = {
  ["territorio-expansion-red"]     = { first = 6,  rest = 1 },
  ["territorio-expansion-green"]   = { first = 8,  rest = 1 },
  ["territorio-expansion-blue"]    = { first = 10, rest = 1 },
  ["territorio-expansion-purple"]  = { first = 12, rest = 1 },
  ["territorio-expansion-yellow"]  = { first = 15, rest = 1 },
  ["territorio-resource-synthesis"] = { first = 6, rest = 0 },
}

function research.on_research_finished(event)
  local tech = event.research
  if not (tech and tech.valid) then return end

  local grant = GRANTS[tech.name]
  if not grant then return end

  local awarded = storage.territorio.awarded_levels
  awarded[tech.force.name] = awarded[tech.force.name] or {}
  local prev = awarded[tech.force.name][tech.name] or 0

  -- In on_research_finished a repeatable tech's `level` sits one past the level just
  -- completed -- except once it is fully researched (finite max_level), where it is exact.
  -- Deriving `completed` this way is also robust to multi-level jumps (console research).
  local completed = tech.researched and tech.level or (tech.level - 1)
  if completed <= prev then return end

  local total = 0
  for lvl = prev + 1, completed do
    total = total + ((lvl == 1) and grant.first or grant.rest)
  end
  awarded[tech.force.name][tech.name] = completed

  local available = tokens.add(tech.force, total)
  gui.refresh_force(tech.force)
  tech.force.print({ "territorio-message.tokens-awarded", total, available })
end

return research
