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

-- Sync-batched dispatch (design-set-batching.md). Inside a `M.batch(fn)`
-- scope a `.set` writes its slot eagerly (reads stay fresh) but only queues
-- the fiber; when the OUTERMOST batch exits, the queue collapses (duplicates,
-- fibers covered by a dirty ancestor, fibers unmounted since they were
-- queued) and each affected root gets its subtree renders plus ONE
-- commit_and_flush — all before batch() returns, so no stale frame is ever
-- shown. Outside any batch, `.set` keeps the original synchronous
-- render-per-set behavior, so external callers are unaffected until they opt
-- in. The state is module-global on purpose: one user event may touch several
-- roots, and they should share the batch.
local batch_depth = 0
local flushing = false
---@type { env: Env, root: Fiber, fiber: Fiber }[]
local dirty = {}

-- Sets fired DURING a flush pass (render-time corrections, effects) queue for
-- a follow-up pass; a chain that never settles is a livelock, not progress.
local MAX_PASSES = 32

---@param env Env
---@param root_fiber Fiber
---@param scheduled Fiber
local function queue_or_render(env, root_fiber, scheduled)
	if batch_depth > 0 or flushing then
		dirty[#dirty + 1] = { env = env, root = root_fiber, fiber = scheduled }
	else
		render_pass(env, scheduled)
		commit_and_flush(env, root_fiber)
	end
end

-- Collapse one pass's dirty list: drop duplicates, fibers with a dirty
-- ancestor (that ancestor's render pass re-renders them anyway), and fibers
-- that no longer reach their root (unmounted since they were queued — their
-- parent link is cleared by reconciler.unmount_fiber).
---@param entries { env: Env, root: Fiber, fiber: Fiber }[]
---@return { env: Env, root: Fiber, fiber: Fiber }[]
local function collapse(entries)
	local dirty_set = {}
	for _, e in ipairs(entries) do
		dirty_set[e.fiber] = true
	end
	local out, taken = {}, {}
	for _, e in ipairs(entries) do
		if not taken[e.fiber] then
			taken[e.fiber] = true
			local covered = false
			local top = e.fiber
			local p = e.fiber.parent
			while p do
				if dirty_set[p] then
					covered = true
				end
				top = p
				p = p.parent
			end
			if not covered and top == e.root then
				out[#out + 1] = e
			end
		end
	end
	return out
end

-- Drain the dirty queue: render every collapsed fiber's subtree, then commit
-- each affected root ONCE (in first-dirtied order). Each pass commits before
-- the next starts so effects always observe a mounted, flushed tree; their
-- sets queue for the next pass.
local function run_passes()
	local passes = 0
	while dirty[1] do
		passes = passes + 1
		if passes > MAX_PASSES then
			error("fibrous: batched state updates did not settle after " .. MAX_PASSES .. " render passes", 0)
		end
		local entries = dirty
		dirty = {}
		local order, buckets = {}, {}
		for _, e in ipairs(collapse(entries)) do
			local bucket = buckets[e.env]
			if not bucket then
				bucket = { env = e.env, root = e.root, fibers = {} }
				buckets[e.env] = bucket
				order[#order + 1] = bucket
			end
			bucket.fibers[#bucket.fibers + 1] = e.fiber
		end
		for _, bucket in ipairs(order) do
			for _, f in ipairs(bucket.fibers) do
				render_pass(bucket.env, f)
			end
			commit_and_flush(bucket.env, bucket.root)
		end
	end
end

local function flush_batch()
	flushing = true
	local ok, err = pcall(run_passes)
	flushing = false
	dirty = {}
	if not ok then
		error(err, 0)
	end
end

local unpack_ = unpack or table.unpack
local function pack(...)
	return { n = select("#", ...), ... }
end

-- Run `fn(...)` inside a batch scope and return its results. Nesting is
-- allowed; only the outermost exit flushes. If `fn` errors, the queued sets
-- are STILL flushed (their slot writes happened, so the world must catch up)
-- and the error then propagates to the caller.
function M.batch(fn, ...)
	batch_depth = batch_depth + 1
	local res = pack(pcall(fn, ...))
	batch_depth = batch_depth - 1
	if batch_depth == 0 and not flushing and dirty[1] then
		local fok, ferr = pcall(flush_batch)
		if not res[1] then
			error(res[2], 0)
		end
		if not fok then
			error(ferr, 0)
		end
	elseif not res[1] then
		error(res[2], 0)
	end
	return unpack_(res, 2, res.n)
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
		queue_or_render(env, fiber, scheduled)
	end
	root._env = env

	fiber.ctx = hooks.make_ctx(env.schedule)
	return root
end

return M
