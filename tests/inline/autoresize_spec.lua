-- Auto-sized raw_buffer growth (requests.md: content-sized render="focus"
-- cells act wonky while typing). An auto-sized raw_buffer measures as its
-- LIVE line count, but nothing scheduled a flush for a plain buffer edit:
-- the build memo's rb_count bust only helps once a flush runs for some other
-- reason. So typing scrolled inside a stale-height float, and the eventual
-- unrelated flush resized it around a drifted view. These specs pin the
-- contract: the box grows in the same tick the buffer does, focused or not,
-- and a focused content-sized float never scrolls internally.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function subwin_of(handle)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[w].fibrous_anchor == handle.winid then
      return w, vim.api.nvim_win_get_config(w)
    end
  end
  return nil
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

-- 1-based row (in the root buffer) of the first line containing `text`.
local function root_row_of(handle, text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
    if line:find(text, 1, true) then
      return i
    end
  end
  return nil
end

local function app_with(bufnr, render)
  return function()
    return {
      comp = ui.col,
      props = {},
      children = {
        { comp = ui.label, props = { text = "head" } },
        { comp = ui.raw_buffer, props = { bufnr = bufnr, render = render, wrap = false } },
        { comp = ui.label, props = { text = "tail" } },
      },
    }
  end
end

describe("inline auto-sized raw_buffer growth", function()
  it("an unfocused widget's box grows when its buffer gains lines", function()
    local bufnr = make_buf({ "one", "two", "three" })
    local handle = mount.floating(app_with(bufnr, "always"), {}, { width = 12, height = 10, mode = "scroll" })
    assert.equal(5, root_row_of(handle, "tail")) -- head + 3 rows + itself

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "four", "five" })
    vim.wait(500, function()
      return root_row_of(handle, "tail") == 7
    end, 10)

    assert.equal(7, root_row_of(handle, "tail"))
    local _, cfg = subwin_of(handle)
    assert.equal(5, cfg.height)

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("a focused render=focus widget grows live as lines are typed, view pinned", function()
    local bufnr = make_buf({ "one", "two", "three" })
    local handle = mount.floating(app_with(bufnr, "focus"), {}, { width = 12, height = 10, mode = "scroll" })

    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub) -- WinEnter reveals the focus float

    -- REAL typing at the bottom line: nvim scrolls the stale-height float
    -- the moment the new line appears, before any fibrous code runs — the
    -- relayout must both grow the float and reassert its view
    vim.api.nvim_feedkeys("Go" .. vim.api.nvim_replace_termcodes("typed<Esc>", true, false, true), "xt", false)
    vim.wait(500, function()
      return root_row_of(handle, "tail") == 6
    end, 10)

    -- the box and float grew in place
    assert.equal(6, root_row_of(handle, "tail"))
    local _, cfg = subwin_of(handle)
    assert.equal(4, cfg.height)

    -- still focused, no internal scroll, cursor where the typing left it
    assert.equal(sub, vim.api.nvim_get_current_win())
    local v = vim.api.nvim_win_call(sub, vim.fn.winsaveview)
    assert.equal(1, v.topline)
    assert.equal(4, vim.api.nvim_win_get_cursor(sub)[1])

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("typing past the viewport bottom scrolls the ROOT, like a real buffer would", function()
    local bufnr = make_buf({ "one", "two", "three", "four" })
    -- head(1) + 4 cell rows + tail = 6 rows: exactly fills the 6-row root
    local handle = mount.floating(app_with(bufnr, "focus"), {}, { width = 12, height = 6, mode = "scroll" })

    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_feedkeys("Go" .. vim.api.nvim_replace_termcodes("five<CR>six<Esc>", true, false, true), "xt", false)
    vim.wait(500, function()
      local v = vim.api.nvim_win_call(handle.winid, vim.fn.winsaveview)
      return v.topline == 2
    end, 10)

    -- the page scrolled down one: the cursor's row (cell line 6 = root row 7)
    -- is the viewport's last row
    local rv = vim.api.nvim_win_call(handle.winid, vim.fn.winsaveview)
    assert.equal(2, rv.topline)

    -- the float covers the visible slice and shows the cursor's line
    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.equal(6, vim.api.nvim_win_get_cursor(sub)[1])
    local v = vim.api.nvim_win_call(sub, vim.fn.winsaveview)
    local cfg = vim.api.nvim_win_get_config(sub)
    -- visible float rows show through the cursor's buffer line
    assert.is_true(v.topline + cfg.height - 1 >= 6)

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("deleting lines shrinks the box live too", function()
    local bufnr = make_buf({ "one", "two", "three", "four" })
    local handle = mount.floating(app_with(bufnr, "focus"), {}, { width = 12, height = 10, mode = "scroll" })

    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_feedkeys("Gdd", "xt", false)
    vim.wait(500, function()
      return root_row_of(handle, "tail") == 5
    end, 10)

    assert.equal(5, root_row_of(handle, "tail"))
    local _, cfg = subwin_of(handle)
    assert.equal(3, cfg.height)
    local v = vim.api.nvim_win_call(sub, vim.fn.winsaveview)
    assert.equal(1, v.topline)

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
