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
---@field parent? Fiber              the fiber this one was reconciled under (nil at the root)
---@field self_tick? integer         tick of this fiber's own last change (render or state flip)
---@field tree_tick? integer         tick of the last change anywhere in this fiber's subtree
local Fiber = {}
Fiber.__index = Fiber

-- Pre-size the hash part so the fields added over a fiber's life (render
-- output, reconciliation links, dirtiness ticks, a host's memoized node)
-- never force a rehash. LuaJIT-only; plain Lua falls back to {}.
local ok, table_new = pcall(require, "table.new")
if not ok then
	table_new = function()
		return {}
	end
end

---@param component Component
---@param props? table
---@return Fiber
function Fiber.new(component, props)
	local fiber = table_new(0, 16)
	fiber.type = component
	fiber.props = props or {}
	fiber.hooks = {}
	fiber.hook_index = 0
	return setmetatable(fiber, Fiber)
end

-- Dirtiness clock ("subtree memoization"): every change pass takes a fresh
-- tick; a host compares fiber ticks against the tick of its last flush to
-- decide whether a subtree can possibly have changed. Monotonic and global —
-- ticks are only ever compared, never counted.
local tick = 0

---@return integer
function Fiber.next_tick()
	tick = tick + 1
	return tick
end

---@return integer
function Fiber.current_tick()
	return tick
end

-- Record that `fiber`'s subtree changed at tick `t`: mark it and every
-- ancestor (their subtrees contain the change). The render pass stamps
-- self_tick on each fiber it actually renders; touch covers the path ABOVE
-- the entry point, which is not re-rendered but is no longer clean.
---@param fiber Fiber|nil
---@param t integer
function Fiber.touch(fiber, t)
	while fiber do
		fiber.tree_tick = t
		fiber = fiber.parent
	end
end

return Fiber
