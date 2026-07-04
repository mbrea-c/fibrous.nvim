-- The two subwindow render policies, side by side (see props.render on
-- text_input/raw_buffer). Subwindows never capture the cursor: hjkl glides
-- straight over them (the page mirrors their text, so the cursor sits on real
-- characters and yanks copy real text); <CR>, a click, or i/a enter one, and
-- hjkl at the buffer's edge steps back out.
--
--   render = "always"  the editable float is always visible on top — live
--                      highlighting, but it covers the page (a visual
--                      selection's highlight skips it).
--   render = "focus"   the float is hidden until you enter the widget; until
--                      then you see the mirror with the buffer's queryable
--                      highlights (regex syntax, diagnostics, extmarks)
--                      transcribed onto it.
--
-- Same lua buffer contents in both, so the fidelity difference is visible.
-- The buffers linewrap (raw_buffer default) — the mirror wraps identically —
-- and the focused widget's border takes the themed accent.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local LINES = {
  "-- a real lua buffer, shown twice; this comment wraps in the box",
  "local function greet(name)",
  "  return ('hi, %s!'):format(name)",
  "end",
  "return greet('fibrous')",
}

local function Policies(ctx)
  local bufs = ctx.use_ref(nil)
  if not bufs.current then
    local function make()
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, LINES)
      vim.bo[b].syntax = "lua"
      return b
    end
    bufs.current = { make(), make() }
  end
  ctx.use_effect(function()
    local a, b = bufs.current[1], bufs.current[2]
    return function()
      pcall(vim.api.nvim_buf_delete, a, { force = true })
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end, {})

  local function editor(label, bufnr, render)
    return {
      comp = ui.col,
      props = { grow = 1, gap = 1 },
      children = {
        { comp = ui.label, props = { text = label, hl = "Title" } },
        {
          -- wrap is the raw_buffer default — the long first line shows the
          -- mirror reproducing the float's line wrapping. The border takes
          -- the themed focus accent while the widget is being edited.
          comp = ui.raw_buffer,
          props = { bufnr = bufnr, border = true, render = render, height = #LINES + 3 },
        },
      },
    }
  end

  return {
    comp = ui.col,
    props = { padding = { x = 1 }, gap = 1 },
    children = {
      {
        comp = ui.paragraph,
        props = {
          text = "hjkl glides over both editors. <CR> or i enters one; "
            .. "hjkl at its edges steps back out. q quits.",
          hl = "Comment",
        },
      },
      {
        comp = ui.row,
        props = { gap = 3 },
        children = {
          editor('render = "always"', bufs.current[1], "always"),
          editor('render = "focus"', bufs.current[2], "focus"),
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Policies, {}, { width = 76, height = 16 })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
