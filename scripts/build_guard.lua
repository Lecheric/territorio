-- The building-placement half of the boundary.
--
-- WHY two events: on_built_entity covers the player's hand and blueprint ghosts;
-- on_robot_built_entity covers a construction bot finishing anything. Bots fly and biters
-- path completely unrestricted -- the gate is only on the *result* of a build landing
-- outside owned territory, never on the mover.

local util = require("scripts.util")
local state = require("scripts.state")
local missile_battery = require("scripts.missile_battery")

local build_guard = {}

local function in_owned_territory(entity)
  local cx, cy = util.pos_to_chunk(entity.position)
  return state.is_unlocked(entity.surface.index, entity.force.name, cx, cy)
end

-- The build gate only applies where the mod confines the player (Nauvis for now). Off
-- Nauvis -- space platforms, other planets -- building is unrestricted.
local function guarded(entity)
  return entity and entity.valid and state.is_managed_surface(entity.surface)
end

local function notify(player, position)
  if player and player.valid then
    player.create_local_flying_text({ text = { "territorio-message.area-locked" }, position = position })
  end
end

function build_guard.on_built_entity(event)
  local entity = event.entity
  if not guarded(entity) then return end

  -- Two separate refusals share one refund path: outside owned territory, or a second
  -- Missile Battery (one per force per surface -- no prototype field expresses that).
  local duplicate = missile_battery.is_duplicate(entity)
  if not duplicate and in_owned_territory(entity) then return end

  local player = event.player_index and game.get_player(event.player_index) or nil
  local position = entity.position

  -- mine_entity returns the placement item(s) to the player (spilling if full) and removes
  -- the entity -- the correct "refund + destroy" for a just-placed building or a ghost.
  if player and player.valid then
    player.mine_entity(entity, true)
  else
    entity.destroy()
  end
  if duplicate then
    if player and player.valid then
      player.create_local_flying_text({
        text = { "territorio-message.battery-limit" }, position = position,
      })
    end
  else
    notify(player, position)
  end
end

function build_guard.on_robot_built_entity(event)
  local entity = event.entity
  if not guarded(entity) then return end
  if not missile_battery.is_duplicate(entity) and in_owned_territory(entity) then return end

  -- Hand the placeable item back to the bot so it carries it home to storage, rather than
  -- destroying it outright and losing the resource.
  local robot = event.robot
  local items = entity.prototype.items_to_place_this
  local stack = items and items[1]
  if stack and robot and robot.valid then
    robot.get_inventory(defines.inventory.robot_cargo).insert(stack)
  elseif stack then
    entity.surface.spill_item_stack({
      position = entity.position,
      stack = stack,
      enable_looted = false,
      allow_belts = false,
    })
  end
  entity.destroy()
end

return build_guard
