-- The fiber execution context (design.md §1A). Tracks which fiber is currently
-- rendering so hooks can resolve their persistent storage without that fiber
-- being threaded through every call. Pure Lua, no Neovim awareness.

local M = {}

-- The currently-executing fiber, or nil when no render is in progress.
---@type Fiber|nil
local CURRENT = nil

-- The fiber that is rendering right now. Errors if called outside a render,
-- which is exactly the misuse we want to catch (hooks called at the top level).
---@return Fiber
function M.current()
  assert(CURRENT, "hooks can only be called during a component render")
  return CURRENT
end

-- Run `fn` with `fiber` installed as the current fiber, restoring the previous
-- one afterwards even if `fn` errors. Returns whatever `fn` returns.
---@generic T
---@param fiber Fiber
---@param fn fun(): T
---@return T
function M.with_current(fiber, fn)
  local prev = CURRENT
  CURRENT = fiber
  local ok, result = pcall(fn)
  CURRENT = prev
  if not ok then
    error(result)
  end
  return result
end

-- Advance the current fiber's hook cursor and return (creating on first render)
-- the slot for this call site. Hook call order must be stable across renders —
-- the positional-slot contract React relies on.
---@return HookSlot
function M.next_hook_slot()
  local fiber = M.current()
  fiber.hook_index = fiber.hook_index + 1
  local slot = fiber.hooks[fiber.hook_index]
  if not slot then
    slot = {}
    fiber.hooks[fiber.hook_index] = slot
  end
  return slot
end

return M
