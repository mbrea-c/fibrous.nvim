-- Native split mode demo (design.md §3B). The app is anchored over a real
-- vertical split pane via `mount_as_window_host`: it renders as floating overlays
-- bound `relative="win"` to the pane, the geometry-sync engine keeps them aligned
-- when you resize with `<C-w>>` / `<C-w><`, the <C-w> shims keep focus from
-- stranding inside an overlay, and closing the pane (`:q`) auto-unmounts the app.

local nr = require("nui-reactive")
local el = require("nui-reactive.components")
local util = require("examples.util")

local function Sidebar(ctx, props)
  local selected = ctx.use_state(1)

  ctx.use_effect(function()
    props.actions.current = {
      next = function() selected.set(math.min(selected.get() + 1, #props.items)) end,
      prev = function() selected.set(math.max(selected.get() - 1, 1)) end,
    }
  end, {})

  local cur = selected.get()
  local lines = { "", "  Project Explorer", "  ─────────────────" }
  for i, item in ipairs(props.items) do
    lines[#lines + 1] = (i == cur and "  ▸ " or "    ") .. item
  end
  vim.list_extend(lines, {
    "",
    "  ─────────────────",
    "  j/k  move   q  close",
    "  <C-w>> / <C-w><  resize",
  })

  return {
    comp = el.col,
    props = {},
    children = {
      { comp = el.text, props = { lines = lines } },
    },
  }
end

local M = {}

function M.run()
  local items = { "init.lua", "reconciler.lua", "nui_host.lua", "floating.lua", "window_host.lua" }
  local actions = { current = {} }
  local handle = nr.mount_as_window_host(Sidebar, { items = items, actions = actions }, {
    split = { direction = "vertical", position = "left", size = 36 },
    behavior = { intercept_wincmd = true, auto_unmount = true },
  })
  handle.focus()
  return util.bind(handle, {
    { "n", "j", function() actions.current.next() end, { desc = "next item" } },
    { "n", "k", function() actions.current.prev() end, { desc = "prev item" } },
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
