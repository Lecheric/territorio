-- Expansion tokens: a plain per-force counter in storage. Never an item.
-- storage.territorio.tokens[force.name] = <int>  (seeded in scripts/state.lua)

local tokens = {}

function tokens.get(force)
  return storage.territorio.tokens[force.name] or 0
end

function tokens.add(force, amount)
  local t = storage.territorio.tokens
  t[force.name] = (t[force.name] or 0) + amount
  return t[force.name]
end

--- Spend `amount` (default 1). Returns true on success, false if the force cannot afford it.
function tokens.spend(force, amount)
  amount = amount or 1
  local t = storage.territorio.tokens
  local current = t[force.name] or 0
  if current < amount then return false end
  t[force.name] = current - amount
  return true
end

return tokens
