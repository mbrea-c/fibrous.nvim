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

-- Mount a component INTO an existing window: no covering float, the window
-- shows the host buffer itself. Cheaper on resize than mount_window and one
-- fewer window in the layout; in exchange it takes the window over, and hands
-- the embedder's buffer back on unmount.
---@type fun(component: Component, props?: table, opts?: InlineBufferMountOpts): InlineSplitHandle
M.mount_buffer = mount.buffer

-- The component set: host primitives (col/row/text/text_input/raw_buffer) and
-- the built-in widgets (label, paragraph, button, checkbox).
M.ui = require("fibrous.inline.components")

-- The default theme: Fibrous* highlight groups (override with :hi / a
-- colorscheme — they are `default = true` links), style defaults per `theme`
-- key (theme.styles) and the default border preset. Adjust before mounting to
-- restyle every instance.
M.theme = require("fibrous.inline.theme")

-- Run `fn(...)` as one batched dispatch: state sets inside it update their
-- values immediately (reads stay fresh) but render once, at batch exit,
-- before this call returns. Fibrous already batches its own dispatches
-- (component handlers, input callbacks); wrap YOUR entry points — external
-- keymaps, timers, ACP/job callbacks — when a handler touches several states.
---@type fun(fn: function, ...): ...
M.batch = require("fibrous.reactive.runtime").batch

return M
