-- Component-scoped subtree reconciliation (design.md §1A). Given a fiber, it
-- renders the component, turns the returned element into child specs, and diffs
-- those against the existing child fibers — reusing a fiber (and its hook state)
-- whenever the component `type` matches at the same position.
--
-- Host primitives (VNode `comp` is a `{ __host = <tag> }` descriptor) are the
-- leaves where the VDOM meets the real UI. The reconciler stays renderer-
-- agnostic: it never touches nui directly, it just drives the injected
-- HostConfig at create/update/destroy time. This keeps the layer pure and lets
-- tests run reconciliation against a mock host. (Mirrors React's HostConfig.)

local Fiber = require("nui-reactive.reactive.fiber")
local context = require("nui-reactive.reactive.context")
local hooks = require("nui-reactive.reactive.hooks")

---@class VNode
---@field comp Component|HostDescriptor   component function, or a host primitive descriptor
---@field props? table
---@field children? VNode[]

---@class HostDescriptor
---@field __host string   the primitive's tag (e.g. "text", "row")

---@class HostConfig
---@field create_instance fun(tag: string, props: table): any
---@field update_instance fun(instance: any, prev_props: table, next_props: table)
---@field destroy_instance fun(instance: any)
---@field commit? fun(root_fiber: Fiber)   apply the committed tree to the screen (post-render)
---@field relayout? fun()                   re-apply geometry without re-rendering (host pane resize)
---@field each_overlay_buffer? fun(fn: fun(bufnr: integer))   walk live overlay leaf buffers (post-commit)
---@field focus? fun()                      focus the core interactive widget
---@field teardown? fun()                  release all host resources (post-unmount)

---@class Env  the per-root reconciliation environment
---@field schedule ScheduleFn
---@field host? HostConfig
---@field effect_queue Fiber[]   fibers with effects pending this pass (flushed post-commit)

local M = {}

-- The host tag of a `comp`, or nil if it is a function component.
---@param comp Component|HostDescriptor
---@return string|nil
local function host_tag(comp)
  if type(comp) == "table" then
    return comp.__host
  end
  return nil
end

-- Tear down a fiber, depth-first: unmount children, run this fiber's own effect
-- cleanups, then destroy its host instance. Resources release child-first.
---@param fiber Fiber
---@param env Env
function M.unmount_fiber(fiber, env)
  if fiber.child_fibers then
    for _, child in ipairs(fiber.child_fibers) do
      M.unmount_fiber(child, env)
    end
    fiber.child_fibers = nil
  end
  for _, slot in ipairs(fiber.hooks) do
    if slot.cleanup then
      slot.cleanup()
      slot.cleanup = nil
    end
  end
  if fiber.instance and env.host then
    env.host.destroy_instance(fiber.instance)
    fiber.instance = nil
  end
end

-- Instantiate a fiber for a child VNode spec: wire up its hook context and, if
-- it is a host primitive, create its backing instance via the HostConfig.
---@param spec VNode
---@param env Env
---@return Fiber
function M.create_fiber(spec, env)
  local fiber = Fiber.new(spec.comp, spec.props)
  fiber.children_specs = spec.children or {}
  fiber.ctx = hooks.make_ctx(env.schedule)
  local tag = host_tag(spec.comp)
  if tag and env.host then
    fiber.instance = env.host.create_instance(tag, fiber.props)
  end
  return fiber
end

-- Reconcile a parent's existing child fibers against fresh child VNode specs.
--
-- Matching is positional: at each index, if the existing fiber's component
-- `type` equals the spec's `comp`, the fiber — and its hook state — is reused
-- (design.md §5: reuse when `type` matches), and a host fiber's instance is
-- updated in place. Otherwise the old fiber is unmounted and a new one mounts.
-- Trailing fibers left over (the new list is shorter) are unmounted.
---@param parent Fiber
---@param specs VNode[]
---@param env Env
function M.reconcile_children(parent, specs, env)
  local old = parent.child_fibers or {}
  local next_children = {}
  for i, spec in ipairs(specs) do
    local existing = old[i]
    if existing and existing.type == spec.comp then
      local prev_props = existing.props
      existing.props = spec.props or {}
      existing.children_specs = spec.children or {}
      if existing.instance and env.host then
        env.host.update_instance(existing.instance, prev_props, existing.props)
      end
      M.render_fiber(existing, env)
      next_children[i] = existing
    else
      if existing then
        M.unmount_fiber(existing, env)
      end
      local fiber = M.create_fiber(spec, env)
      M.render_fiber(fiber, env)
      next_children[i] = fiber
    end
  end
  for i = #specs + 1, #old do
    M.unmount_fiber(old[i], env)
  end
  parent.child_fibers = next_children
end

-- Render a single fiber and reconcile its subtree.
--
-- A function component is invoked (with the fiber installed as the current
-- fiber so hooks resolve) and the element it returns becomes its single child
-- spec. A host primitive isn't called; its children come straight from its
-- VNode.
--
-- Effects are NOT run here — they are queued (in subtree post-order, i.e.
-- children before parents) and flushed by the runtime *after* the host commit,
-- so effects observe a mounted tree and refs point at live buffers (React's
-- render → commit → effects ordering).
---@param fiber Fiber
---@param env Env
---@return VNode|nil rendered
function M.render_fiber(fiber, env)
  local child_specs
  if type(fiber.type) == "function" then
    fiber.hook_index = 0
    fiber.rendered = context.with_current(fiber, function()
      return fiber.type(fiber.ctx, fiber.props)
    end)
    child_specs = fiber.rendered and { fiber.rendered } or {}
  else
    child_specs = fiber.children_specs or {}
  end
  M.reconcile_children(fiber, child_specs, env)
  for _, slot in ipairs(fiber.hooks) do
    if slot.pending then
      env.effect_queue[#env.effect_queue + 1] = fiber
      break
    end
  end
  return fiber.rendered
end

return M
