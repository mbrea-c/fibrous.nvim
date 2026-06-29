-- A Fiber is the persistent runtime record for one component instance. It
-- survives across render cycles so hooks can map to the same storage slots and
-- reconciliation can reuse subtrees whose component `type` is unchanged.
--
-- This module is pure Lua: it has no awareness of Neovim, buffers, or windows.

---@class HookSlot
---@field value? any                current value (use_state)
---@field __initialized? boolean    whether use_state has seeded `value`
---@field deps? any[]               last dependency array (use_effect)
---@field pending? EffectCallback   effect queued to run in the next flush (use_effect)
---@field cleanup? fun()|nil        cleanup from the last effect run (use_effect)
---@field ref? Ref                  stable mutable container (use_ref)

---@alias Component fun(ctx: ReactiveCtx, props: table): VNode|nil

---@class Fiber
---@field type Component             pointer to the functional component definition
---@field props table               configuration attributes passed by the parent
---@field hooks HookSlot[]           sequential storage for use_state / use_effect
---@field hook_index integer         cursor into `hooks`, reset at the start of each render
---@field ctx? ReactiveCtx           the hook context handed to the component
---@field rendered? VNode|nil        the element returned by the last render
---@field children_specs? VNode[]    child VNode specs (host primitives) to reconcile
---@field child_fibers? Fiber[]      reconciled child fibers, indexed positionally
---@field instance? any              backing host instance (host fibers only)
---@field scoped_keymaps? table[]    keymap records (use_keymap) the host binds across this fiber's subtree
local Fiber = {}
Fiber.__index = Fiber

---@param component Component
---@param props? table
---@return Fiber
function Fiber.new(component, props)
  return setmetatable({
    type = component,
    props = props or {},
    hooks = {},
    hook_index = 0,
  }, Fiber)
end

return Fiber
