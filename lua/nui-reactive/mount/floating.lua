-- Standalone floating mount (design.md §3A): the simplest mounting target. The
-- root VNode is arranged by a nui.layout anchored in the editor (or at the
-- cursor) and rendered. Returns an imperative handle (design.md §4) for external
-- control of the live tree.

local runtime = require("nui-reactive.reactive.runtime")
local nui_host = require("nui-reactive.dom.nui_host")

local M = {}

---@class FloatingOpts
---@field relative? string   nui relative ("editor" | "cursor" | "win"); default "editor"
---@field position? string|table   nui position spec; default "50%"
---@field size? table        { width, height }; default { width = "60%", height = "60%" }

---@class AppHandle
---@field set_props fun(new_props: table)   inject new top-level props (top-down pass)
---@field focus fun()                        focus the core interactive widget
---@field unmount fun()                      dismantle the tree and wipe windows

-- Mount `component` as a floating application.
---@param component Component
---@param props? table
---@param opts? FloatingOpts
---@return AppHandle
function M.mount(component, props, opts)
  opts = opts or {}
  local layout_config = {
    relative = opts.relative or "editor",
    position = opts.position or "50%",
    size = opts.size or { width = "60%", height = "60%" },
  }

  local host = nui_host.new(layout_config)
  local root = runtime.create_root(component, props, { host = host })
  root:render()

  return {
    set_props = function(new_props)
      root:set_props(new_props)
    end,
    focus = function()
      if host.focus then
        host.focus()
      end
    end,
    unmount = function()
      root:unmount()
    end,
  }
end

return M
