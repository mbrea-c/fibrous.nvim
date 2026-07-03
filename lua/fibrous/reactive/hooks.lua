-- The hooks implementation (design.md §2 "Core Hooks Interface"): use_state and
-- use_effect, the effect-flush phase, and the per-fiber `ctx` that exposes them.
-- Pure Lua; depends only on the fiber execution context.

local context = require("fibrous.reactive.context")

---@class StateHandle
---@field get fun(): any          read the current value
---@field set fun(value: any)     write a new value and flag the fiber for re-render

---@alias EffectCallback fun(): (fun()|nil)   effect body, optionally returning a cleanup

---@alias ScheduleFn fun(fiber: Fiber)   request a re-render of the given fiber

---@class Ref
---@field current any   mutable slot; for host leaves, populated with a handle at commit

---@class ReactiveCtx
---@field use_state fun(initial: any): StateHandle
---@field use_effect fun(callback: EffectCallback, deps?: any[])
---@field use_ref fun(initial?: any): Ref

local M = {}

-- Shallow per-element comparison of dependency arrays. A nil `next` means "no
-- dependency array given" → always re-run. A nil `prev` means first render.
---@param prev any[]|nil
---@param next any[]|nil
---@return boolean changed
local function deps_changed(prev, next)
  if next == nil or prev == nil then
    return true
  end
  if #prev ~= #next then
    return true
  end
  for i = 1, #next do
    if prev[i] ~= next[i] then
      return true
    end
  end
  return false
end

---@param schedule ScheduleFn
---@param initial any
---@return StateHandle
local function use_state(schedule, initial)
  local fiber = context.current()
  local slot = context.next_hook_slot()
  if not slot.__initialized then
    slot.value = initial
    slot.__initialized = true
  end
  return {
    get = function()
      return slot.value
    end,
    set = function(value)
      if slot.value ~= value then
        slot.value = value
        schedule(fiber)
      end
    end,
  }
end

-- A stable mutable container that persists across renders without triggering
-- one when written (React's useRef). Hosts may fill `ref.current` on host
-- leaves at commit time so effects can drive the real UI imperatively.
---@param initial? any
---@return Ref
local function use_ref(initial)
  local slot = context.next_hook_slot()
  if not slot.ref then
    slot.ref = { current = initial }
  end
  return slot.ref
end

---@param callback EffectCallback
---@param deps? any[]
local function use_effect(callback, deps)
  local slot = context.next_hook_slot()
  if deps_changed(slot.deps, deps) then
    -- Defer execution to the flush phase (after the component has fully
    -- rendered), matching React's "effects run after commit" ordering.
    slot.pending = callback
  end
  slot.deps = deps
end

-- Run any effects flagged during this fiber's render. Each pending effect runs
-- its previous cleanup (if any) first, then stores the new cleanup it returns.
---@param fiber Fiber
function M.flush_effects(fiber)
  for _, slot in ipairs(fiber.hooks) do
    if slot.pending then
      if slot.cleanup then
        slot.cleanup()
        slot.cleanup = nil
      end
      local cleanup = slot.pending()
      slot.cleanup = type(cleanup) == "function" and cleanup or nil
      slot.pending = nil
    end
  end
end

-- Build the hook context handed to a fiber's component. `schedule` is how a
-- state change asks the runtime to re-render the affected fiber.
---@param schedule ScheduleFn
---@return ReactiveCtx
function M.make_ctx(schedule)
  return {
    use_state = function(initial)
      return use_state(schedule, initial)
    end,
    use_effect = function(callback, deps)
      return use_effect(callback, deps)
    end,
    use_ref = function(initial)
      return use_ref(initial)
    end,
  }
end

return M
