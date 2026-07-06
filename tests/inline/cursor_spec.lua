-- Cursor stability across a flush. When a line's BYTE layout changes but its
-- DISPLAY layout doesn't — an animated line of glyphs whose UTF-8 lengths differ
-- (the weave water indicator: 3-byte block chars vs 4-byte octants, all one cell
-- wide) — a naive set_lines keeps the cursor's byte column, so the cursor drifts
-- across cells as bytes shift under it ("dragged by the waves"). The splice
-- preserves each showing window's cursor DISPLAY column instead.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function dispcol(handle)
  local p = vim.api.nvim_win_get_cursor(handle.winid)
  local line = vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] or ""
  return vim.fn.strdisplaywidth(line:sub(1, p[2]))
end

describe("inline.cursor", function()
  it("keeps the cursor's display column when a line's byte layout shifts under it", function()
    local toggle
    local function App(ctx)
      local s = ctx.use_state(false)
      toggle = s
      -- '▂' is 3 bytes, '𜴧' is 4 bytes; both a single display cell. Toggling the
      -- leading glyph changes the byte length to the LEFT of the cursor.
      local head = s.get() and "▂" or "𜴧"
      return {
        comp = ui.col,
        props = {},
        children = { { comp = ui.label, props = { text = head .. "abcde" } } },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })
    vim.api.nvim_set_current_win(handle.winid)

    -- park the cursor on the 3rd cell (the 'b')
    local line = vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]
    vim.api.nvim_win_set_cursor(handle.winid, { 1, vim.fn.byteidx(line, 3) })
    assert.equal(3, dispcol(handle))

    toggle.set(true) -- the head glyph loses a byte, left of the cursor

    assert.equal(3, dispcol(handle)) -- display column preserved, not dragged
    handle.unmount()
  end)
end)
