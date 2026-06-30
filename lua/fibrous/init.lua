-- fibrous public entry point. A React-like reactive UI framework for
-- Neovim. See design.md for the architecture.

local floating = require("fibrous.mount.floating")
local window_host = require("fibrous.mount.window_host")

local M = {}

-- Mount a component as a standalone floating application (design.md §3A).
-- Returns an imperative handle for external control.
---@type fun(component: Component, props?: table): AppHandle
M.mount = floating.mount

-- Mount a component anchored over a native split pane (design.md §3B). Returns
-- an imperative handle (with the host pane's winid) for external control.
---@type fun(component: Component, props?: table, opts?: WindowHostOpts): WindowAppHandle
M.mount_as_window_host = window_host.mount

-- Built-in host primitives (popup, …) for building component trees.
M.components = require("fibrous.components")

-- Built-in composite hooks (built atop use_state/use_effect/use_ref). Also the
-- reference pattern for user-defined hooks: a function taking `ctx`.
M.hooks = {
  use_keymap = require("fibrous.hooks.use_keymap"),
}

return M
