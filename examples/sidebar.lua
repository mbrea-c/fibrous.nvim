-- Native split mode demo. The app mounts over a real vertical split pane via
-- `mount_split`: the inline canvas covers the pane edge to edge, resizing with
-- `<C-w>>` / `<C-w><` rewraps and re-anchors, and closing the pane (`:q`)
-- auto-unmounts the app.
--
-- Selection is cursor-driven, the inline-host way: j/k are plain cursor
-- motions, the hover bar tracks the row you are on, and <CR> selects it (each
-- row is an interactive node with a role + on_press).

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local function Sidebar(ctx, props)
  local selected = ctx.use_state(1)
  local cur = selected.get()

  local children = {
    { comp = ui.label, props = { text = "Project Explorer", hl = "Title" } },
    { comp = ui.label, props = { text = "" } },
  }
  for i, item in ipairs(props.items) do
    children[#children + 1] = {
      comp = ui.label,
      props = {
        text = (i == cur and "▸ " or "  ") .. item,
        hl = i == cur and "Directory" or nil,
        -- a plain label made interactive: the hit-map only needs a role
        role = "button",
        on_press = function() selected.set(i) end,
        hover_hl = "Visual",
        align_self = "start",
      },
    }
  end
  vim.list_extend(children, {
    { comp = ui.label, props = { text = "" } },
    { comp = ui.label, props = { text = "j/k move · <CR> select · q close", hl = "Comment" } },
    { comp = ui.label, props = { text = "<C-w>> / <C-w><  resize", hl = "Comment" } },
  })

  return { comp = ui.col, props = { padding = { x = 1, y = 1 } }, children = children }
end

local M = {}

function M.run()
  local items = { "init.lua", "reconciler.lua", "layout.lua", "canvas.lua", "subwin.lua" }
  local handle = nr.mount_split(Sidebar, { items = items }, {
    split = { direction = "vertical", position = "left", size = 36 },
  })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
