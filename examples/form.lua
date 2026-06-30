-- Uncontrolled text input demo (design.md §5.3). The `text_input` buffer is the
-- source of truth while you type — keystrokes are handled natively by Neovim, no
-- per-keystroke re-render. Each edit fires `on_change`, which we mirror into
-- `use_state` so the label below updates reactively. The mount auto-focuses the
-- input and drops you into insert mode.

local nr = require("fibrous")
local el = require("fibrous.components")
local util = require("examples.util")

local function Form(ctx)
  local typed = ctx.use_state("")
  local submitted = ctx.use_state(nil)

  local value = typed.get()
  local last = submitted.get()

  return {
    comp = el.col,
    props = {},
    children = {
      {
        comp = el.text,
        props = { size = 1, lines = { " Type something (Enter submits, q quits in normal mode):" } },
      },
      {
        comp = el.text_input,
        props = {
          size = 3,
          border = "rounded",
          on_change = function(v) typed.set(v) end,
          on_submit = function(v) submitted.set(v) end,
        },
      },
      {
        comp = el.text,
        props = {
          grow = 1,
          border = "rounded",
          lines = {
            "  live length : " .. #value,
            "  live text   : " .. value,
            "",
            "  submitted    : " .. (last and ("[" .. last .. "]") or "(none yet)"),
          },
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Form, {}, { size = { width = 56, height = 12 } })
  handle.focus()
  vim.cmd("startinsert")
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
