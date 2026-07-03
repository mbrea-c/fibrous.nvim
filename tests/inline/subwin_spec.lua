-- The subwindow clipping risk-spike (tracker "NEW UI HOST" task 4, decision:
-- clipping first). A text_input is laid out like any inline node — its border
-- is even painted inline in the root buffer — but its CONTENT box is covered
-- by a real, editable float anchored to the root float. When the root buffer
-- scrolls, the float is repositioned by the topline offset; partial occlusion
-- resizes it to the visible rows and re-anchors its own viewport (topline);
-- full occlusion hides it. WinScrolled drives the live resync (known accepted
-- artifact: it fires post-redraw, so a one-frame swim).
--
-- Scroll repositioning is asserted deterministically here (set topline, then
-- resync through the same code path the autocmd calls); the swim itself is
-- interactive-only and gets evaluated by eye.

local mount = require("fibrous.inline.mount")

local col = { __host = "col" }
local text = { __host = "text" }
local text_input = { __host = "text_input" }

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- The (single) subwindow float anchored to the root float, or nil.
local function subwin_of(handle)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == "win" and cfg.win == handle.winid then
      return w, cfg
    end
  end
  return nil
end

-- Scroll the root float so `topline` is the first visible buffer line.
local function scroll_root(handle, topline)
  vim.api.nvim_win_call(handle.winid, function()
    vim.fn.winrestview({ topline = topline, lnum = topline, col = 0 })
  end)
end

-- An input above 6 filler lines: content rows 0-2 (explicit height 3), fillers
-- rows 3-8. In a width-6 height-4 scroll-mode float, scrolling puts the input
-- partially, then fully, above the viewport.
local function ClippingApp()
  local children = {
    { comp = text_input, props = { height = 3, value = "l1\nl2\nl3" } },
  }
  for i = 1, 6 do
    children[#children + 1] = { comp = text, props = { text = "f" .. i } }
  end
  return { comp = col, props = {}, children = children }
end

describe("inline.subwin", function()
  it("a text_input gets an editable float at its layout content box; its border stays inline", function()
    local function App()
      return {
        comp = col,
        props = {},
        children = {
          { comp = text, props = { text = "above" } },
          { comp = text_input, props = { border = true } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 5 })

    local sub, cfg = subwin_of(handle)
    assert.is_not_nil(sub)
    -- content box of the input: inside the border, under the text row
    assert.equal(2, cfg.row)
    assert.equal(1, cfg.col)
    assert.equal(8, cfg.width)
    assert.equal(1, cfg.height)
    assert.is_true(vim.bo[vim.api.nvim_win_get_buf(sub)].modifiable)
    -- the border is painted in the ROOT buffer (inline), not on the float
    local root_lines = lines_of(handle.bufnr)
    assert.equal("╭────────╮", root_lines[2])
    assert.equal("╰────────╯", root_lines[4])

    handle.unmount()
    assert.is_nil(subwin_of(handle))
  end)

  it("seeds the input buffer from props.value", function()
    local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })

    local sub, cfg = subwin_of(handle)
    assert.is_not_nil(sub)
    assert.equal(0, cfg.row)
    assert.equal(3, cfg.height)
    assert.same({ "l1", "l2", "l3" }, lines_of(vim.api.nvim_win_get_buf(sub)))

    handle.unmount()
  end)

  it("partial occlusion at the top clips the float and re-anchors its viewport", function()
    local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })
    local sub = subwin_of(handle)

    scroll_root(handle, 2) -- one content row scrolled off above
    handle.relayout()

    local cfg = vim.api.nvim_win_get_config(sub)
    assert.falsy(cfg.hide)
    assert.equal(0, cfg.row)
    assert.equal(2, cfg.height)
    -- the hidden first input row is scrolled out of the float's own viewport
    assert.equal(2, vim.fn.line("w0", sub))

    handle.unmount()
  end)

  it("full occlusion hides the float; scrolling back shows it again", function()
    local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })
    local sub = subwin_of(handle)

    scroll_root(handle, 4) -- all three input rows are above the viewport
    handle.relayout()
    assert.is_true(vim.api.nvim_win_get_config(sub).hide)

    scroll_root(handle, 1)
    handle.relayout()
    local cfg = vim.api.nvim_win_get_config(sub)
    assert.falsy(cfg.hide)
    assert.equal(0, cfg.row)
    assert.equal(3, cfg.height)
    assert.equal(1, vim.fn.line("w0", sub))

    handle.unmount()
  end)

  it("a subwindow's own scroll and cursor survive root scrolls", function()
    -- an editor-style raw_buffer: 12 lines shown through a 3-row window, so
    -- it has scroll state of its own that clipping must compose with, not own
    local buf = vim.api.nvim_create_buf(false, true)
    local buflines = {}
    for i = 1, 12 do
      buflines[i] = "b" .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buflines)
    local function App()
      local children = {
        { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 3 } },
      }
      for i = 1, 6 do
        children[#children + 1] = { comp = text, props = { text = "f" .. i } }
      end
      return { comp = col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 6, height = 4, mode = "scroll" })
    local sub = subwin_of(handle)

    -- the user scrolled inside the editor: showing lines 4-6, cursor at (5, 1)
    vim.api.nvim_win_call(sub, function()
      vim.fn.winrestview({ topline = 4, lnum = 5, col = 1 })
    end)

    scroll_root(handle, 2) -- clips the editor's top row
    handle.relayout()
    -- clip composes with the internal scroll: one MORE row scrolled out
    assert.equal(5, vim.fn.line("w0", sub))
    local pos = vim.api.nvim_win_get_cursor(sub)
    assert.same({ 5, 1 }, pos) -- cursor untouched (still visible)

    scroll_root(handle, 1) -- unclip
    handle.relayout()
    -- the user's own view is back, not reset to the top
    assert.equal(4, vim.fn.line("w0", sub))
    assert.same({ 5, 1 }, vim.api.nvim_win_get_cursor(sub))

    handle.unmount()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("WinScrolled resync is wired on the root float and cleared on unmount", function()
    local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })

    local aus = vim.api.nvim_get_autocmds({ event = "WinScrolled" })
    local wired = 0
    for _, au in ipairs(aus) do
      if (au.group_name or ""):find("FibrousInlineSubwin", 1, true) then
        wired = wired + 1
        assert.equal(tostring(handle.winid), au.pattern)
      end
    end
    assert.equal(1, wired)

    handle.unmount()
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "WinScrolled" })) do
      assert.is_false((au.group_name or ""):find("FibrousInlineSubwin", 1, true) ~= nil)
    end
  end)

  it(":q on a subwindow float closes the whole UI, like :q on the root", function()
    local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })
    local sub = subwin_of(handle)
    local sub_buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(sub)
    vim.cmd("quit")

    -- the cascade is scheduled (windows can't be closed from inside WinClosed)
    vim.wait(200, function()
      return not vim.api.nvim_win_is_valid(handle.winid)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    assert.is_false(vim.api.nvim_buf_is_valid(sub_buf))
    assert.is_nil(subwin_of(handle))
  end)

  it("removing the component from the tree destroys its float and buffer", function()
    local setter
    local function App(ctx)
      local show = ctx.use_state(true)
      setter = show
      local children = { { comp = text, props = { text = "top" } } }
      if show.get() then
        children[#children + 1] = { comp = text_input, props = {} }
      end
      return { comp = col, props = {}, children = children }
    end
    local before = #vim.api.nvim_list_wins()
    local handle = mount.floating(App, {}, { width = 8, height = 4 })
    local sub = subwin_of(handle)
    assert.is_not_nil(sub)
    local sub_buf = vim.api.nvim_win_get_buf(sub)

    setter.set(false)

    assert.is_nil(subwin_of(handle))
    assert.is_false(vim.api.nvim_buf_is_valid(sub_buf))

    handle.unmount()
    assert.equal(before, #vim.api.nvim_list_wins())
  end)
end)
