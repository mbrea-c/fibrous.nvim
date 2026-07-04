-- The reactive runtime entry point: a `Root` that binds a top-level component
-- to the reconciler and exposes the imperative lifecycle (render / unmount).
-- The heavy lifting lives in the focused sibling modules:
--   context.lua     fiber execution pointer + hook-slot cursor
--   hooks.lua       use_state / use_effect / make_ctx
--   reconciler.lua  create / render / reconcile / unmount
-- This layer is pure Lua and fully unit-testable outside of Neovim.

local Fiber = require("fibrous.reactive.fiber")
local hooks = require("fibrous.reactive.hooks")
local reconciler = require("fibrous.reactive.reconciler")

local M = {}

---@class RootOpts
---@field host? HostConfig   bridge that maps host primitives to real instances

---@class Root
---@field _fiber Fiber
---@field _env Env
local Root = {}
Root.__index = Root

-- Render `entry`'s subtree under a fresh dirtiness tick: every fiber the pass
-- visits is stamped (reconciler), and the path ABOVE the entry — clean itself,
-- but its subtree changed — is touched, so hosts can memoize untouched
-- subtrees by comparing fiber ticks against their last flush.
---@param env Env
---@param entry Fiber
local function render_pass(env, entry)
	env.tick = Fiber.next_tick()
	reconciler.render_fiber(entry, env)
	Fiber.touch(entry, env.tick)
end

-- Apply one render pass to the world: push the committed tree to the host
-- (mount / relayout / buffer writes), then flush queued effects. Effects run
-- AFTER commit so they observe a mounted tree (refs point at live buffers).
-- `scheduled` is the fiber that was re-rendered; the host commit always works
-- from the root so the whole Box tree stays consistent.
---@param env Env
---@param root_fiber Fiber
local function commit_and_flush(env, root_fiber)
	if env.host and env.host.commit then
		env.host.commit(root_fiber)
	end
	local queue = env.effect_queue
	env.effect_queue = {}
	for _, fiber in ipairs(queue) do
		hooks.flush_effects(fiber)
	end
end

-- Render the whole tree from the root component.
---@return Root
function Root:render()
	render_pass(self._env, self._fiber)
	commit_and_flush(self._env, self._fiber)
	return self
end

-- Replace the root component's props and re-render top-down (design.md §4
-- `set_props`): an external authority injecting new configuration into the tree.
---@param new_props table
function Root:set_props(new_props)
	self._fiber.props = new_props or {}
	render_pass(self._env, self._fiber)
	commit_and_flush(self._env, self._fiber)
end

-- Tear down the whole tree: run effect cleanups + destroy host instances
-- depth-first, then release the host bridge's collective resources (the Layout).
function Root:unmount()
	reconciler.unmount_fiber(self._fiber, self._env)
	if self._env.host and self._env.host.teardown then
		self._env.host.teardown()
	end
end

-- Create a reactive root bound to a top-level component and its props. A single
-- reconciliation `env` (shared `schedule` + optional host bridge) flows through
-- the tree: a state change re-renders just the owning fiber's subtree (keeping
-- updates component-scoped), then re-commits the whole tree to the host.
---@param component Component
---@param props? table
---@param opts? RootOpts
---@return Root
function M.create_root(component, props, opts)
	local root = setmetatable({}, Root)
	local fiber = Fiber.new(component, props)
	root._fiber = fiber

	---@type Env
	local env = { host = opts and opts.host or nil, effect_queue = {} }
	env.schedule = function(scheduled)
		render_pass(env, scheduled)
		commit_and_flush(env, fiber)
	end
	root._env = env

	fiber.ctx = hooks.make_ctx(env.schedule)
	return root
end

return M
