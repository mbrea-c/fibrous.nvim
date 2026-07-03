-- Focus traversal between the root buffer and subwindow floats (tracker "NEW
-- UI HOST" task 7). Native cursor motions are the primary navigation:
--
--   in   moving the root cursor into a subwindow's content box focuses its
--        float at the corresponding cell (CursorMoved, root window current)
--   out  h/j/k/l at the input buffer's edge exit to the root buffer adjacent
--        to the widget; <C-w>h/j/k/l exit unconditionally; <C-d>/<C-u> hand
--        focus back to the root and scroll it (page motions are never trapped)

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- The (single) subwindow float anchored to the root float of `handle`.
local function subwin_of(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "win" and cfg.win == handle.winid then
      return win
    end
  end
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- head / input("abcdef") / tail inside padding x=1, so the input's rect starts
-- at x=1 and exits in every direction have somewhere to land.
local function PaddedApp()
  return {
    comp = ui.col,
    props = { padding = { x = 1 } },
    children = {
      { comp = ui.label, props = { text = "head" } },
      { comp = ui.text_input, props = { value = "abcdef", height = 1 } },
      { comp = ui.label, props = { text = "tail" } },
    },
  }
end

describe("inline.focus", function()
  it("moving the root cursor into an input region focuses its float at that cell", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 }) -- the input row, cell 3
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })

    assert.equal(sub, vim.api.nvim_get_current_win())
    -- content box starts at x=1, so cell 3 is col 2 inside the input
    assert.same({ 1, 2 }, vim.api.nvim_win_get_cursor(sub))
    handle.unmount()
  end)

  it("edge motions exit to the adjacent root cell: k above, j below, h left, l right", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    -- k on the first line exits above, keeping the column
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 2 })
    press("k")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 1, 3 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- j on the last line exits below
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 2 })
    press("j")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 3, 3 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- h at col 0 exits left of the widget's border box (rect x=1 → root col 0)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("h")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- l on the last character exits right of the border box (x=1 + w=8 → col 9)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 5 })
    press("l")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 2, 9 }, vim.api.nvim_win_get_cursor(handle.winid))

    handle.unmount()
  end)

  it("exits from a bordered input land ON the border cell, not past it", function()
    -- Entry crosses the border one keypress at a time (the border rows/cols
    -- are ordinary root cells), so exits must be symmetric: one step out of
    -- the content box is the border cell, not the far side of the box.
    local function App()
      return {
        comp = ui.col,
        props = { padding = { x = 1 } },
        children = {
          { comp = ui.label, props = { text = "head" } },
          -- no explicit height: `height` sizes the BORDER box, and a bordered
          -- input needs its default single content row
          { comp = ui.text_input, props = { border = true, value = "abcdef" } },
        },
      }
    end
    -- rows (0-based): 0 head; 1 top border; 2 " │abcdef  │ "; 3 bottom border
    -- content box: y=2, x=2..9 (stretched); border cells at x=1 and x=10
    local handle = mount.floating(App, {}, { width = 12, height = 6 })
    local sub = subwin_of(handle)

    -- h at col 0 → the LEFT border cell (cell 1 = byte 1)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("h")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 3, 1 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- l past the last char → the RIGHT border cell (cell 10 = byte 12)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 5 })
    press("l")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 3, 12 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- k → the TOP border row, keeping the column (cell 2 = byte 4 after ╭)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("k")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 2, 4 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- j → the BOTTOM border row
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("j")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 4, 4 }, vim.api.nvim_win_get_cursor(handle.winid))

    handle.unmount()
  end)

  it("non-edge motions stay inside the subwindow", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.text_input, props = { value = "l1\nl2", height = 2 } },
          { comp = ui.label, props = { text = "tail" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("j")
    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(sub))

    -- h at col 0 of a widget flush with the root's left edge has nowhere to
    -- go: it stays put instead of exiting
    press("h")
    assert.equal(sub, vim.api.nvim_get_current_win())

    handle.unmount()
  end)

  it("<C-w> window motions exit unconditionally, even away from the edge", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          { comp = ui.text_input, props = { value = "l1\nl2", height = 2 } },
          { comp = ui.label, props = { text = "tail" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 4 })
    local sub = subwin_of(handle)

    -- <C-w>j from the FIRST line still exits below the widget
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    press("<C-w>j")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(handle.winid))

    -- <C-w>k from the last line exits above
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 2, 0 })
    press("<C-w>k")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.winid))

    handle.unmount()
  end)

  it("<C-d> inside a subwindow hands focus back to the root and scrolls it", function()
    local children = {
      { comp = ui.text_input, props = { value = "top input", height = 1 } },
    }
    for i = 1, 12 do
      children[#children + 1] = { comp = ui.label, props = { text = "line " .. i } }
    end
    local function App()
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 4, mode = "scroll" })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("<C-d>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.is_true(vim.fn.line("w0", handle.winid) > 1)

    handle.unmount()
  end)
end)
