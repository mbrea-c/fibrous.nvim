-- Uncontrolled text input demo. The `text_input` float's buffer is the source
-- of truth while you type — keystrokes are handled natively by Neovim, no
-- per-keystroke re-render of the input itself. Each edit fires `on_change`,
-- which we mirror into `use_state` so the panel below updates reactively;
-- `<CR>` fires `on_submit`. Focus is explicit: the cursor glides over the
-- input like any other cell — press i (or <CR>) on it to edit, and h/j/k/l
-- at its edges step back out into the page.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local function Form(ctx)
  local typed = ctx.use_state("")
  local submitted = ctx.use_state(nil)

  local value = typed.get()
  local last = submitted.get()

  return {
    comp = ui.col,
    props = { style = { padding = { x = 1 } }, gap = 1 },
    children = {
      { comp = ui.label, props = { text = "Type something (Enter submits, q quits in normal mode):" } },
      {
        comp = ui.text_input,
        props = {
          height = 3,
          style = { border = "rounded" },
          on_change = function(v) typed.set(v) end,
          on_submit = function(v) submitted.set(v) end,
        },
      },
      {
        comp = ui.col,
        props = { grow = 1, style = { border = "rounded", padding = { x = 1 } } },
        children = {
          { comp = ui.label, props = { text = "live length : " .. #value } },
          { comp = ui.label, props = { text = "live text   : " .. value } },
          { comp = ui.label, props = { text = "" } },
          { comp = ui.label, props = { text = "submitted   : " .. (last and ("[" .. last .. "]") or "(none yet)") } },
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Form, {}, { width = 56, height = 13 })
  handle.focus()
  -- Park the cursor on the input's box — one `i` away from typing (focus is
  -- explicit; the cursor no longer dives into the float by itself).
  vim.api.nvim_win_set_cursor(handle.winid, { 4, 3 })
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
