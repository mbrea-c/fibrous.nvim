-- use_keymap: a component-scoped keymap hook.
--
-- Neovim has no DOM-style event bubbling — a keymap is a buffer-local (or global)
-- resource that fires based on which window is focused. To make a keymap behave
-- like a React `onKeyDown` on a *component* (active while focus is anywhere
-- inside that component), it must be bound on every leaf buffer in the
-- component's rendered subtree.
--
-- That set of buffers is only knowable at commit time (a descendant can mount
-- new buffers without its ancestor re-rendering), so this hook does not bind the
-- map itself. It records the binding *intent* on the calling component's fiber;
-- the Nui Bridge applies every fiber's recorded keymaps to its subtree leaves on
-- each commit (refreshing the closure each time, so the handler always sees the
-- latest render's state — the React "fresh handler" guarantee).
--
-- Because it is built purely from the current fiber + a hook slot, it is also the
-- canonical worked example of a user-defined hook: a plain function taking `ctx`,
-- subject to the usual Rules of Hooks (call it unconditionally, once per binding,
-- at the top of render).

local context = require("nui-reactive.reactive.context")

---@class KeymapSpec
---@field lhs string                     the left-hand side (e.g. "j", "<CR>", "<C-s>")
---@field rhs fun()                       handler invoked when the key is pressed
---@field mode? string|string[]           mode(s); default "n"
---@field desc? string                    keymap description
---@field nowait? boolean                 set the <nowait> flag

-- Register a keymap scoped to the calling component's subtree. Call once per
-- binding, unconditionally, during render.
---@param ctx ReactiveCtx   the component's hook context (for the stable slot)
---@param spec KeymapSpec
local function use_keymap(ctx, spec)
  local fiber = context.current()

  -- A stable per-call-site record. Created once, then mutated in place each
  -- render so the bridge (which holds the same table reference) always reads the
  -- current handler/keys without us re-registering anything.
  local slot = ctx.use_ref()
  if not slot.current then
    slot.current = {}
    fiber.scoped_keymaps = fiber.scoped_keymaps or {}
    fiber.scoped_keymaps[#fiber.scoped_keymaps + 1] = slot.current
  end

  local record = slot.current
  record.mode = spec.mode or "n"
  record.lhs = spec.lhs
  record.rhs = spec.rhs
  record.opts = { desc = spec.desc, nowait = spec.nowait }
end

return use_keymap
