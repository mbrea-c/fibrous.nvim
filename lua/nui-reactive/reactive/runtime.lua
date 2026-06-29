-- The reactive runtime: the "brain" from design.md §1A. It owns the fiber
-- execution context, the hooks implementation, and (later) subtree
-- reconciliation. It is pure Lua and unit-testable outside of Neovim.

local Fiber = require("nui-reactive.reactive.fiber")

---@class VNode
---@field comp Component|table   component function, or a host primitive descriptor
---@field props? table
---@field children? VNode[]

---@class StateHandle
---@field get fun(): any          read the current value
---@field set fun(value: any)     write a new value and flag the fiber for re-render

---@alias EffectCallback fun(): (fun()|nil)   effect body, optionally returning a cleanup

---@class ReactiveCtx
---@field use_state fun(initial: any): StateHandle
---@field use_effect fun(callback: EffectCallback, deps?: any[])

local M = {}

-- The currently-executing fiber. Tracked module-side so nested machinery can
-- discover "who is rendering" without threading it through every call.
---@type Fiber|nil
local CURRENT_FIBER = nil

---@return Fiber
local function current_fiber()
  assert(CURRENT_FIBER, "hooks can only be called during a component render")
  return CURRENT_FIBER
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

-- Advance the hook cursor and return (creating if first render) the slot for
-- the current call site. Hook call order must be stable across renders — this
-- is the same positional-slot contract React relies on.
---@return HookSlot
local function next_hook_slot()
  local fiber = current_fiber()
  fiber.hook_index = fiber.hook_index + 1
  local slot = fiber.hooks[fiber.hook_index]
  if not slot then
    slot = {}
    fiber.hooks[fiber.hook_index] = slot
  end
  return slot
end

-- Shallow per-element comparison of dependency arrays. A nil `next` means "no
-- dependency array given" → always re-run. A nil `prev` means first render.
---@param prev any[]|nil
---@param next any[]|nil
---@return boolean changed
local function deps_changed(prev, next)
  if next == nil then
    return true
  end
  if prev == nil then
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

---@param callback EffectCallback
---@param deps? any[]
local function use_effect(callback, deps)
  local slot = next_hook_slot()
  if deps_changed(slot.deps, deps) then
    -- Defer execution to the flush phase (after the component has fully
    -- rendered), matching React's "effects run after commit" ordering.
    slot.pending = callback
  end
  slot.deps = deps
end

---@param root Root
---@param initial any
---@return StateHandle
local function use_state(root, initial)
  local fiber = current_fiber()
  local slot = next_hook_slot()
  if slot.value == nil and not slot.__initialized then
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
        root:_schedule(fiber)
      end
    end,
  }
end

---------------------------------------------------------------------------
-- Root
---------------------------------------------------------------------------

---@class Root
---@field _fiber Fiber
local Root = {}
Root.__index = Root

-- Build the hook context handed to a fiber's component. Bound to the fiber and
-- root so hooks resolve their storage and can request re-renders.
---@param root Root
---@param fiber Fiber
---@return ReactiveCtx
local function make_ctx(root, fiber)
  return {
    use_state = function(initial)
      return use_state(root, initial)
    end,
    use_effect = function(callback, deps)
      return use_effect(callback, deps)
    end,
  }
end

-- Run any effects flagged during this fiber's render. Each pending effect runs
-- its previous cleanup (if any) first, then stores the new cleanup it returns.
---@param fiber Fiber
local function flush_effects(fiber)
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

-- Render a single fiber: reset its hook cursor, run the component with the
-- fiber installed as CURRENT_FIBER, and store the returned element.
---@param fiber Fiber
---@return VNode|nil
function Root:_render_fiber(fiber)
  fiber.hook_index = 0
  local prev = CURRENT_FIBER
  CURRENT_FIBER = fiber
  local ok, result = pcall(fiber.type, fiber.ctx, fiber.props)
  CURRENT_FIBER = prev
  if not ok then
    error(result)
  end
  fiber.rendered = result
  flush_effects(fiber)
  return result
end

-- Tear down a fiber: run all pending cleanups so external resources acquired in
-- effects are released. (Descends into child fibers once reconciliation lands.)
---@param fiber Fiber
local function unmount_fiber(fiber)
  for _, slot in ipairs(fiber.hooks) do
    if slot.cleanup then
      slot.cleanup()
      slot.cleanup = nil
    end
  end
end

-- Tear down the whole tree, running effect cleanups and releasing the root.
function Root:unmount()
  unmount_fiber(self._fiber)
end

-- Re-render request originating from a state change. For now this re-runs the
-- owning fiber synchronously; batching + reconciliation arrive in later steps.
---@param fiber Fiber
function Root:_schedule(fiber)
  self:_render_fiber(fiber)
end

-- Render the whole tree from the root component.
---@return Root
function Root:render()
  self:_render_fiber(self._fiber)
  return self
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Create a reactive root bound to a top-level component and its props.
---@param component Component
---@param props? table
---@return Root
function M.create_root(component, props)
  local root = setmetatable({}, Root)
  local fiber = Fiber.new(component, props)
  fiber.ctx = make_ctx(root, fiber)
  root._fiber = fiber
  return root
end

return M
