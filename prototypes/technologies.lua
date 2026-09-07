-- Territorio's ONLY prototypes: one repeatable "expansion" technology per vanilla science
-- tier. They carry no in-game effect -- scripts/research.lua awards expansion tokens on
-- on_research_finished, reading the completed level to decide the amount. `effects = {}`
-- is valid (base "space-science-pack" does the same); the tech-tree text comes from the
-- [technology-description] locale.
--
-- Zero new art: reuses the base "landfill" technology icon (declared exactly as base does).
--
-- Balance note: MAX_LEVEL, the count_formulas and the per-tier token grants (in
-- research.lua) are all first-pass numbers -- expected to need tuning against a real
-- playthrough. Ceiling right now ~ 10 starting + ~231 from research.

-- Every icon below goes through tech_icon(): the borrowed vanilla art, washed red so the
-- whole Territorio family is distinguishable from the vanilla tech it borrowed from.
local tech_icon = require("prototypes.tech_icon")

local ICON = "__base__/graphics/technology/landfill.png"

-- The difficulty dial (settings.lua). Every level past the first grants +1 token, so the
-- level cap IS how much of the map you can ever own. Playtest 5 found 10 too long a tail,
-- so Standard is now 5 and 10 survives as the relaxed option.
local LEVELS = { easy = 10, medium = 5, hard = 3 }
local MAX_LEVEL = LEVELS[settings.startup["territorio-expansion-levels"].value] or 5

local RESEARCH_TIME = 30

-- key -> { prerequisite tech(s), cumulative ingredient packs, cost formula }
--
-- GATING RULE (playtest 5): every science pack a tech CHARGES must be guaranteed by its
-- prerequisite closure. Miss one and the tech goes available the moment its listed
-- prerequisites are done, you queue it, and research stalls on a pack you cannot make yet.
-- The prereq list is per-tier rather than one string because that is not always the
-- deepest pack: utility-science-pack does NOT require production-science-pack in vanilla
-- (its chain is robotics / processing-unit / low-density-structure), so the yellow tier
-- has to name both.
local TIERS = {
  { key = "red", order = "a", prereq = { "automation-science-pack" },
    packs = { "automation-science-pack" },
    formula = "100 * L" },
  { key = "green", order = "b", prereq = { "logistic-science-pack" },
    packs = { "automation-science-pack", "logistic-science-pack" },
    formula = "150 * L" },
  { key = "blue", order = "c", prereq = { "chemical-science-pack" },
    packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack" },
    formula = "200 * L" },
  { key = "purple", order = "d", prereq = { "production-science-pack" },
    packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack",
              "production-science-pack" },
    formula = "300 * L" },
  { key = "yellow", order = "e",
    prereq = { "utility-science-pack", "production-science-pack" },
    packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack",
              "production-science-pack", "utility-science-pack" },
    formula = "400 * L" },
}

local techs = {}
for _, tier in pairs(TIERS) do
  local ingredients = {}
  for _, pack in pairs(tier.packs) do
    ingredients[#ingredients + 1] = { pack, 1 }
  end

  techs[#techs + 1] = {
    type = "technology",
    name = "territorio-expansion-" .. tier.key,
    icons = tech_icon(ICON),
    effects = {},
    prerequisites = tier.prereq,
    unit = {
      count_formula = tier.formula,
      ingredients = ingredients,
      time = RESEARCH_TIME,
    },
    max_level = MAX_LEVEL,
    upgrade = true,
    order = "z-territorio-" .. tier.order,
  }
end

data:extend(techs)

-- Artillery-strike tier techs (Phase 4a). Kills bank strike charges regardless; these gate
-- whether you can *fire* and how hard. scripts/strikes.lua reads which is researched.
-- Chained so they appear in order. Reuses the base "artillery" technology icon.
--
-- Playtest 5 reshuffle: the Strike is now the LATE-game capstone, not a mid-game
-- escalation. The Missile Battery (blue + military) covers the middle of the run on its
-- own -- playtest 5 ran Mortar -> Battery -> Strike and reported it scaled cleanly with
-- Strike held back until purple and yellow were both online. So tier 1 gates on
-- production AND utility, and the three tiers are now a cost ladder (450 / 600 / 900)
-- rather than a science-pack ladder. They also bank charges faster per tier (see
-- scripts/strikes.lua), so the upgrade is felt between barrages and not only inside one.
--
-- THE COUNTS ARE LOW ON PURPOSE, and this is the rule for every tech in this mod: research
-- cost cannot be judged against a vanilla base. The whole point of Territorio is a base
-- constrained by AREA, so science-per-minute is capped by how many chunks you were willing
-- to buy -- a count that reads as a normal late-game number in vanilla is a wall here.
-- First cut of this ladder was 500 / 900 / 1500 and playtest 5 called 1500 unreachable.
--
-- `-N` names + `upgrade = true` (playtest-4): three independent techs, each with its own
-- prerequisites and ingredients, that the tech-tree GUI merges into ONE card sharing tier
-- 1's name and description -- the same mechanism as vanilla mining-productivity-1..4 and
-- as territorio-resource-synthesis. These read as "the same thing, bigger", which is what
-- that merge is for. See CLAUDE.md's tech-naming rule.
local STRIKE_ICON = "__base__/graphics/technology/artillery.png"

data:extend({
  {
    type = "technology",
    name = "territorio-artillery-strike",
    icons = tech_icon(STRIKE_ICON),
    effects = {},
    prerequisites = {
      "military", "production-science-pack", "utility-science-pack",
    },
    unit = {
      count = 450,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "production-science-pack", 1 },
        { "utility-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-s1",
  },
  {
    type = "technology",
    name = "territorio-artillery-strike-2",
    icons = tech_icon(STRIKE_ICON),
    effects = {},
    prerequisites = { "territorio-artillery-strike" },
    unit = {
      count = 600,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "production-science-pack", 1 },
        { "utility-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-s2",
  },
  {
    type = "technology",
    name = "territorio-artillery-strike-3",
    icons = tech_icon(STRIKE_ICON),
    effects = {},
    prerequisites = { "territorio-artillery-strike-2" },
    unit = {
      count = 900,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "production-science-pack", 1 },
        { "utility-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-s3",
  },
})

-- Automated border wall (Phase 4b). No in-game effect -- scripts/walls.lua checks whether
-- this is researched and, if so, keeps a free vanilla stone-wall ring on the outer edge of
-- the force's territory. Reuses the base "stone-wall" technology icon.
data:extend({
  {
    type = "technology",
    name = "territorio-border-wall",
    icons = tech_icon("__base__/graphics/technology/stone-wall.png"),
    effects = {},
    prerequisites = { "stone-wall", "military" },
    unit = {
      count = 75,
      ingredients = { { "automation-science-pack", 1 } },
      time = 30,
    },
    order = "z-territorio-w1",
  },
})

-- Frontier surveillance (Phase 4-surveillance). No in-game effect -- scripts/surveillance.lua
-- checks which is researched and charts a fog band that many chunks outside the whole
-- territory border, so nests past the front are visible and strikes can be aimed. The deep
-- tier also feeds the "sector pulse" charge. Reuses the base "radar" technology icon.
-- count values first-pass.
data:extend({
  {
    type = "technology",
    name = "territorio-surveillance",
    icons = tech_icon("__base__/graphics/technology/radar.png"),
    effects = {},
    prerequisites = { "radar", "chemical-science-pack" },
    unit = {
      count = 150,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-v1",
  },
  {
    type = "technology",
    name = "territorio-surveillance-deep",
    icons = tech_icon("__base__/graphics/technology/radar.png"),
    effects = {},
    prerequisites = { "territorio-surveillance", "production-science-pack" },
    unit = {
      count = 250,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "production-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-v2",
  },
})

-- Resource Prospecting. Deliberately NOT a surveillance tier and deliberately EARLY:
-- red+green, right before blue. Its whole job is the early-game question "is there oil
-- that way, or should I spend the tokens synthesizing instead?" -- which has to be
-- answerable BEFORE chemical science, where Frontier Surveillance (chemical) and the
-- sector pulse (production) do not exist yet. So it is standalone and event-driven
-- (research + territory change) rather than riding the pulse. scripts/surveillance.lua.
data:extend({
  {
    type = "technology",
    name = "territorio-prospecting",
    icons = tech_icon("__base__/graphics/technology/radar.png"),
    effects = {},
    prerequisites = { "radar", "logistic-science-pack" },
    unit = {
      count = 150,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-v0",
  },
})

-- Resource synthesis / "Ore Generator" (playtest-3). No in-game effect -- once researched,
-- scripts/resource_gen.lua lets the player spend expansion tokens to fill an owned chunk
-- with a resource patch, so a tile-locked base doesn't have to ribbon out to distant ore.
--
-- 5 chained techs, `-N`-numbered and `upgrade = true` on purpose (see CLAUDE.md's tech-
-- naming rule): this deliberately mirrors vanilla `mining-productivity-1..4` -- multiple
-- independent tech prototypes, each free to have its OWN prerequisites/ingredients, that
-- Factorio's tech-tree GUI auto-merges into one compact card sharing tier 1's name/
-- description (a TRUE repeatable/max_level tech can't do per-level ingredients at all --
-- see the v0.1.19-22 history in LLM-current-sprint.md for why that path was abandoned).
-- scripts/resource_gen.lua reads richness AND which resources are unlocked from which of
-- these 5 are researched.
--   L1 red+green            -> unlocks iron, coal, oil
--   L2 + blue               -> unlocks copper, stone
--   L3 + yellow + purple    -> unlocks uranium
--   L4 + space (if Space Age is active; skipped on base-only)
--   L5 + space at 1000x the L4 amount (base-only: base packs at 5x instead)
-- Reuses the base "steel-processing" technology icon throughout. All counts first-pass.
--
-- NOTE: this is the 3rd structural revision of this tech in one sprint (repeatable tech ->
-- 5 word-suffixed techs -> this). A save with progress on any earlier version will very
-- likely need to re-research from tier 1 -- there's no clean migration across renames.
local SPACE_AGE = mods["space-age"] ~= nil

local function synth_packs(amount, space_amount)
  local ingredients = {
    { "automation-science-pack", amount }, { "logistic-science-pack", amount },
    { "chemical-science-pack", amount }, { "utility-science-pack", amount },
    { "production-science-pack", amount },
  }
  if SPACE_AGE and space_amount then
    ingredients[#ingredients + 1] = { "space-science-pack", space_amount }
  end
  return ingredients
end

local SYNTH_ICON = "__base__/graphics/technology/steel-processing.png"

-- Tiers 4 and 5 charge space science under Space Age, so under Space Age they must also
-- REQUIRE it -- otherwise they unlock the moment tier 3 lands and stall the queue on a pack
-- that needs a rocket first. Conditional so the base-only tree is untouched, exactly
-- mirroring the conditional in synth_packs above.
local function synth_prereq(base)
  if SPACE_AGE then base[#base + 1] = "space-science-pack" end
  return base
end

data:extend({
  {
    type = "technology",
    name = "territorio-resource-synthesis",
    icons = tech_icon(SYNTH_ICON),
    effects = {},
    prerequisites = { "logistic-science-pack", "steel-processing" },
    unit = {
      count = 150,
      ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-o1",
  },
  {
    type = "technology",
    name = "territorio-resource-synthesis-2",
    icons = tech_icon(SYNTH_ICON),
    effects = {},
    prerequisites = { "territorio-resource-synthesis", "chemical-science-pack" },
    unit = {
      count = 250,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-o2",
  },
  {
    type = "technology",
    name = "territorio-resource-synthesis-3",
    icons = tech_icon(SYNTH_ICON),
    effects = {},
    prerequisites = {
      "territorio-resource-synthesis-2", "utility-science-pack", "production-science-pack",
    },
    unit = {
      count = 400,
      ingredients = synth_packs(1),
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-o3",
  },
  {
    type = "technology",
    name = "territorio-resource-synthesis-4",
    icons = tech_icon(SYNTH_ICON),
    effects = {},
    prerequisites = synth_prereq({ "territorio-resource-synthesis-3" }),
    unit = {
      count = 100,
      ingredients = synth_packs(1, 1),
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-o4",
  },
  {
    type = "technology",
    name = "territorio-resource-synthesis-5",
    icons = tech_icon(SYNTH_ICON),
    effects = {},
    prerequisites = synth_prereq({ "territorio-resource-synthesis-4" }),
    unit = {
      count = 100,
      -- Base-only (no Space Age): no space-science-pack to scale, so lean on 5x the base
      -- packs instead to still land as a real step up from tier 4.
      ingredients = SPACE_AGE and synth_packs(1, 1000) or synth_packs(5),
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-o5",
  },
})

-- Base Beautification (playtest-3). No in-game effect -- scripts/beautify.lua checks which
-- tier is researched and paves the whole territory with the matching floor tile
-- (stone brick -> concrete -> refined concrete). Reuses the base "concrete" tech icon.
--
-- `-N` names + `upgrade = true` (playtest-4, was word-suffixed): each tier is literally
-- the same feature at a better floor, so the tech-tree GUI merging all three into one
-- card (sharing tier 1's name/description) is the right read. See CLAUDE.md's rule.
--
-- Counts (500 / 750 / 1000) are the ONE deliberate exception to the research-cost rule in
-- CLAUDE.md, which prices against a ~900 capstone. This is cosmetic plus a walking bonus,
-- so it is meant to be a luxury you buy when you have spare science rather than something
-- on the critical path. Playtest 5 kept the tier-1 price and trimmed the top two from
-- 1000 / 1500, so tier 3 no longer costs more than the artillery capstone.
data:extend({
  {
    type = "technology",
    name = "territorio-beautification",
    icons = tech_icon("__base__/graphics/technology/concrete.png"),
    effects = {},
    prerequisites = { "automation-science-pack" },
    unit = {
      count = 500,
      ingredients = { { "automation-science-pack", 1 } },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-b1",
  },
  {
    type = "technology",
    name = "territorio-beautification-2",
    icons = tech_icon("__base__/graphics/technology/concrete.png"),
    effects = {},
    prerequisites = { "territorio-beautification", "concrete" },
    unit = {
      count = 750,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-b2",
  },
  {
    type = "technology",
    name = "territorio-beautification-3",
    icons = tech_icon("__base__/graphics/technology/concrete.png"),
    effects = {},
    prerequisites = { "territorio-beautification-2", "chemical-science-pack" },
    unit = {
      count = 1000,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-b3",
  },
})

-- Perimeter Defense. No in-game effect -- scripts/walls.lua (T1) and
-- scripts/perimeter_defense.lua (T2-T4) check which of these is researched. Prereq'd on
-- the already-shipped territorio-border-wall (left untouched) rather than extending it,
-- so researched border-wall progress isn't disturbed. Word suffixes (not -N): each tier
-- is a genuinely different feature (repair / 2nd wall layer / mines / denser mines), not
-- "the same thing, bigger" -- see CLAUDE.md's tech-naming rule.
--   T1 auto-repair -- heals damaged (not yet destroyed) border walls on the sweep.
--   T2 "dragon's teeth" -- a staggered stone-wall line 2 tiles beyond the border.
--   T3 land mines -- vanilla land-mine, 5 tiles beyond the border, every 4th tile.
--   T4 denser mines -- same mines, every 2nd tile.
-- T1/T2 reuse the base "stone-wall" tech icon (same family as territorio-border-wall);
-- T3/T4 reuse the base "land-mine" tech icon. Counts first-pass.
data:extend({
  {
    type = "technology",
    name = "territorio-perimeter-defense",
    icons = tech_icon("__base__/graphics/technology/stone-wall.png"),
    effects = {},
    -- logistic-science-pack is named explicitly: the wall chain (stone-wall / military)
    -- only ever guarantees red, so without this the tech unlocks before you can pay green.
    prerequisites = { "territorio-border-wall", "logistic-science-pack" },
    unit = {
      count = 150,
      ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } },
      time = 30,
    },
    order = "z-territorio-p1",
  },
  {
    type = "technology",
    name = "territorio-perimeter-defense-teeth",
    icons = tech_icon("__base__/graphics/technology/stone-wall.png"),
    effects = {},
    prerequisites = { "territorio-perimeter-defense", "chemical-science-pack" },
    unit = {
      count = 250,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-p2",
  },
  {
    type = "technology",
    name = "territorio-perimeter-defense-mines",
    icons = tech_icon("__base__/graphics/technology/land-mine.png"),
    effects = {},
    -- land-mine's chain tops out at military science, so utility has to be named here.
    prerequisites = {
      "territorio-perimeter-defense-teeth", "land-mine", "utility-science-pack",
    },
    unit = {
      count = 400,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "utility-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-p3",
  },
  {
    type = "technology",
    name = "territorio-perimeter-defense-dense-mines",
    icons = tech_icon("__base__/graphics/technology/land-mine.png"),
    effects = {},
    prerequisites = { "territorio-perimeter-defense-mines", "production-science-pack" },
    unit = {
      count = 600,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "utility-science-pack", 1 },
        { "production-science-pack", 1 },
      },
      time = 30,
    },
    order = "z-territorio-p4",
  },
})

-- Chunk refund (playtest-4, item F). No in-game effect -- scripts/refund.lua reads which
-- tier is researched. Every tier refunds 1:1; what research buys is how much of the chunk
-- SURVIVES the sale ("mothballing"), so you can buy it back later and find it intact:
--   T1 red+green                          -- everything destroyed, paving reverted
--   T2 + blue + military                  -- buildings stay, dead and unpowered
--   T3 + production + utility             -- the wall ring stays too, so it decays slowly
-- Two new science packs per tier. Deliberately NO space science: white would break
-- base-game-only play, which the mod still supports (cf. territorio-resource-synthesis-5,
-- which needs a mods["space-age"] conditional for exactly that reason).
--
-- `-N` + upgrade = true: one merged tech-tree card, since each tier is the same feature
-- preserving more. Reuses the base "landfill" icon -- the same art the expansion techs
-- wear, because this is their inverse.
local REFUND_ICON = "__base__/graphics/technology/landfill.png"

data:extend({
  {
    type = "technology",
    name = "territorio-chunk-refund",
    icons = tech_icon(REFUND_ICON),
    effects = {},
    prerequisites = { "logistic-science-pack" },
    unit = {
      count = 100,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-r1",
  },
  {
    type = "technology",
    name = "territorio-chunk-refund-2",
    icons = tech_icon(REFUND_ICON),
    effects = {},
    prerequisites = { "territorio-chunk-refund", "chemical-science-pack", "military-science-pack" },
    unit = {
      count = 250,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "military-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-r2",
  },
  {
    type = "technology",
    name = "territorio-chunk-refund-3",
    icons = tech_icon(REFUND_ICON),
    effects = {},
    prerequisites = {
      "territorio-chunk-refund-2", "production-science-pack", "utility-science-pack",
    },
    unit = {
      count = 500,
      ingredients = {
        { "automation-science-pack", 1 }, { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 }, { "military-science-pack", 1 },
        { "production-science-pack", 1 }, { "utility-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
    order = "z-territorio-r3",
  },
})
