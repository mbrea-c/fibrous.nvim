-- fibrous public entry point. A React-like reactive UI framework for Neovim,
-- rendering component trees inline into one host-owned buffer (text +
-- extmarks) with real editable floats only where a native buffer is needed
-- (text_input, raw_buffer). See design.md for the architecture.

local mount = require("fibrous.inline.mount")

local M = {}

-- Mount a component as a standalone floating application.
---@type fun(component: Component, props?: table, opts?: InlineFloatingOpts): InlineAppHandle
M.mount = mount.floating

-- Mount a component over a freshly opened native split pane.
---@type fun(component: Component, props?: table, opts?: InlineSplitOpts): InlineSplitHandle
M.mount_split = mount.split

-- Mount a component over an existing window.
---@type fun(component: Component, props?: table, opts?: InlineWindowMountOpts): InlineSplitHandle
M.mount_window = mount.window

-- The component set: host primitives (col/row/text/text_input/raw_buffer) and
-- the built-in widgets (label, paragraph, button, checkbox).
M.ui = require("fibrous.inline.components")

return M
