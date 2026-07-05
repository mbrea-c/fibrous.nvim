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
-- partially, then fully, above the viewport. render="always" — these specs
-- assert the SHOWN float's clip geometry (the default policy hides it).
local function ClippingApp()
  local children = {
    { comp = text_input, props = { height = 3, value = "l1\nl2\nl3", render = "always" } },
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
          { comp = text_input, props = { style = { border = true }, render = "always" } },
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
        { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 3, render = "always" } },
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

  -- Entry/exit translation must go through the widget's OWN scroll (base,
  -- leftcol): the mirror shows the scrolled slice, so the buffer line under a
  -- root cell is base + content-row, not content-row + 1. Getting this wrong
  -- is a teleport: you activate the line you see, and land somewhere else.
  describe("entry/exit through a scrolled widget", function()
    -- "head", then an editor-style raw_buffer (12 lines through 3 rows,
    -- nowrap, left margin 2 so horizontal exits have somewhere to land)
    local function editor_app(buf)
      return function()
        local children = {
          { comp = text, props = { text = "head" } },
          {
            comp = { __host = "raw_buffer" },
            props = { bufnr = buf, height = 3, wrap = false, render = "always", style = { margin = { left = 2 } } },
          },
        }
        for i = 1, 6 do
          children[#children + 1] = { comp = text, props = { text = "f" .. i } }
        end
        return { comp = col, props = {}, children = children }
      end
    end

    local function editor_buf()
      local buf = vim.api.nvim_create_buf(false, true)
      local buflines = {}
      for i = 1, 12 do
        buflines[i] = ("line-%02d"):format(i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, buflines)
      return buf
    end

    it("entering lands on the line and column the mirror shows", function()
      local buf = editor_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 10, height = 12 })
      local sub = subwin_of(handle)

      -- the widget scrolled itself both ways: showing lines 4-6 from cell 2
      vim.api.nvim_win_call(sub, function()
        vim.fn.winrestview({ topline = 4, leftcol = 2 })
      end)
      handle.relayout()

      -- root line 3 shows buffer line 5; its cell 3 shows the line's cell 3
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 3, 3 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)

      assert.equal(sub, vim.api.nvim_get_current_win())
      assert.same({ 5, 3 }, vim.api.nvim_win_get_cursor(sub))

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a horizontal exit keeps the on-screen row, not the buffer row", function()
      local buf = editor_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 10, height = 12 })
      local sub = subwin_of(handle)

      vim.api.nvim_win_call(sub, function()
        vim.fn.winrestview({ topline = 4 })
      end)
      handle.relayout()

      -- cursor on buffer line 5 = the widget's second visible row
      vim.api.nvim_set_current_win(sub)
      vim.api.nvim_win_set_cursor(sub, { 5, 0 })
      vim.api.nvim_feedkeys("h", "xt", false)

      assert.equal(handle.winid, vim.api.nvim_get_current_win())
      -- one cell left of the content box, on the SAME screen row
      assert.same({ 3, 1 }, vim.api.nvim_win_get_cursor(handle.winid))

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a vertical exit keeps the on-screen column, not the buffer column", function()
      local buf = editor_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 10, height = 12 })
      local sub = subwin_of(handle)

      vim.api.nvim_win_call(sub, function()
        vim.fn.winrestview({ topline = 1, leftcol = 2 })
      end)
      handle.relayout()

      -- cursor at cell 3 of line 1 = on-screen column 1 of the content box
      vim.api.nvim_set_current_win(sub)
      vim.api.nvim_win_set_cursor(sub, { 1, 3 })
      vim.api.nvim_feedkeys("k", "xt", false)

      assert.equal(handle.winid, vim.api.nvim_get_current_win())
      assert.same({ 1, 3 }, vim.api.nvim_win_get_cursor(handle.winid)) -- "head" row, cell c.x + 1

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("entering through a WRAPPED widget lands on the line the row shows", function()
      -- wrap is raw_buffer's default (and the playground's): one buffer line
      -- can occupy several box rows, so row → line is the mirror's row map,
      -- not base + offset — arithmetic teleports by one line per wrapped row
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "short-1",
        "long-2-" .. ("x"):rep(30), -- 37 cells: three rows of a 16-wide box
        "short-3",
        "short-4",
      })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = "head" } },
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 6 } },
          },
        }
      end, {}, { width = 16, height = 10 })
      local sub = subwin_of(handle)

      -- root row 5 is long-2's third wrapped row (cells 32-36)
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 5, 2 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
      assert.equal(sub, vim.api.nvim_get_current_win())
      assert.same({ 2, 34 }, vim.api.nvim_win_get_cursor(sub)) -- cell 32 + 2

      -- and the row after the wrapped block is short-3 again
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 6, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(sub))

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a horizontal exit from a wrapped widget keeps the on-screen row", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "short-1",
        "long-2-" .. ("x"):rep(30),
        "short-3",
        "short-4",
      })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = "head" } },
            {
              comp = { __host = "raw_buffer" },
              props = { bufnr = buf, height = 6, style = { margin = { left = 2 } } },
            },
          },
        }
      end, {}, { width = 18, height = 10 })
      local sub = subwin_of(handle)

      -- buffer line 3 (short-3) is shown on box row 5 (after 3 wrapped rows)
      vim.api.nvim_set_current_win(sub)
      vim.api.nvim_win_set_cursor(sub, { 3, 0 })
      vim.api.nvim_feedkeys("h", "xt", false)
      assert.equal(handle.winid, vim.api.nvim_get_current_win())
      assert.same({ 6, 1 }, vim.api.nvim_win_get_cursor(handle.winid))

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("page-scrolling while focused does not corrupt the own-scroll bookkeeping", function()
      -- The resize that clipping applies makes nvim re-anchor the FOCUSED
      -- float's topline around its cursor; entry.clip must track that
      -- geometry even though the view is deliberately left alone, or the
      -- own-scroll reconstruction on leave (base = topline - clip) is off by
      -- the clip — a phantom scroll the mirror then renders.
      local handle = mount.floating(ClippingApp, {}, { width = 6, height = 4, mode = "scroll" })
      local sub = subwin_of(handle)

      vim.api.nvim_set_current_win(sub)
      vim.api.nvim_win_set_cursor(sub, { 3, 0 })
      scroll_root(handle, 3) -- clips the two rows above the cursor
      handle.relayout()
      assert.equal(3, vim.fn.line("w0", sub)) -- nvim kept the cursor visible

      vim.api.nvim_set_current_win(handle.winid) -- leave; reposition is deferred
      vim.wait(80, function()
        return false
      end, 10)
      -- the discriminating moment: the leave-time reposition reconstructs the
      -- widget's own scroll and re-extracts the mirror — with a stale clip it
      -- reads base 3 and renders the box from l3 (the NEXT reposition would
      -- cancel the error out again, which is why this asserts here)
      assert.truthy(lines_of(handle.bufnr)[1]:find("l1", 1, true))

      scroll_root(handle, 1)
      handle.relayout()
      -- the widget never scrolled itself: unclipped, it shows from the top,
      -- and the mirror agrees
      assert.equal(1, vim.fn.line("w0", sub))
      assert.truthy(lines_of(handle.bufnr)[1]:find("l1", 1, true))

      handle.unmount()
    end)
  end)

  -- Horizontal root scroll (the root float is nowrap, so leftcol can move —
  -- e.g. a trackpad's ScrollWheelRight): floats must shift with leftcol,
  -- clip at the view's left edge — composing the clip into the widget's own
  -- leftcol, like vertical clipping composes topline — and hide fully-off
  -- widgets. Same deterministic pattern as above: set the view, resync.
  describe("horizontal root scroll", function()
    local function hscroll_root(handle, leftcol)
      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = leftcol })
      end)
    end

    it("left clip: the float narrows and its own view scrolls by the clip", function()
      local function App()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = "head" } },
            { comp = text_input, props = { value = "abcdefghij", render = "always" } },
          },
        }
      end
      local handle = mount.floating(App, {}, { width = 12, height = 4 })
      local sub = subwin_of(handle)

      hscroll_root(handle, 3)
      handle.relayout()

      local cfg = vim.api.nvim_win_get_config(sub)
      assert.falsy(cfg.hide)
      assert.equal(0, cfg.col)
      assert.equal(9, cfg.width)
      -- the 3 hidden cells are scrolled out of the float's own viewport
      local v
      vim.api.nvim_win_call(sub, function()
        v = vim.fn.winsaveview()
      end)
      assert.equal(3, v.leftcol)

      hscroll_root(handle, 0)
      handle.relayout()
      cfg = vim.api.nvim_win_get_config(sub)
      assert.equal(0, cfg.col)
      assert.equal(12, cfg.width)
      vim.api.nvim_win_call(sub, function()
        v = vim.fn.winsaveview()
      end)
      -- the clip composed with (not overwrote) the widget's own leftcol
      assert.equal(0, v.leftcol)

      handle.unmount()
    end)

    it("an unclipped widget right of the scroll shifts left with the page", function()
      local function App()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = ("x"):rep(20) } },
            {
              comp = { __host = "row" },
              props = {},
              children = {
                { comp = text, props = { text = "abcdef" } },
                { comp = text_input, props = { value = "hi", width = 5, render = "always" } },
              },
            },
          },
        }
      end
      local handle = mount.floating(App, {}, { width = 14, height = 4 })
      local sub = subwin_of(handle)
      assert.equal(6, vim.api.nvim_win_get_config(sub).col)

      hscroll_root(handle, 4)
      handle.relayout()

      local cfg = vim.api.nvim_win_get_config(sub)
      assert.falsy(cfg.hide)
      assert.equal(2, cfg.col) -- 6 - 4
      assert.equal(5, cfg.width) -- untouched: no clip
      local v
      vim.api.nvim_win_call(sub, function()
        v = vim.fn.winsaveview()
      end)
      assert.equal(0, v.leftcol)

      handle.unmount()
    end)

    it("a widget fully scrolled off to the left hides; scrolling back reveals", function()
      local function App()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = ("x"):rep(20) } },
            { comp = text_input, props = { value = "hi", width = 4, render = "always" } },
          },
        }
      end
      local handle = mount.floating(App, {}, { width = 12, height = 4 })
      local sub = subwin_of(handle)

      hscroll_root(handle, 6) -- the widget spans cells 0-3: fully off-view
      handle.relayout()
      assert.is_true(vim.api.nvim_win_get_config(sub).hide)

      hscroll_root(handle, 0)
      handle.relayout()
      local cfg = vim.api.nvim_win_get_config(sub)
      assert.falsy(cfg.hide)
      assert.equal(0, cfg.col)
      assert.equal(4, cfg.width)

      handle.unmount()
    end)
  end)

  -- The text mirror: the sub buffer's visible slice is written into the root
  -- canvas cells the float covers. Invisible under an always-shown float, but
  -- it makes the region honest — the gliding cursor sits on real characters,
  -- yank/visual selection get real text — and it IS the view when a
  -- render="focus" widget is unfocused.
  describe("text mirror", function()
    local function editor_app(buf)
      return function()
        local children = {
          { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 3 } },
        }
        for i = 1, 3 do
          children[#children + 1] = { comp = text, props = { text = "f" .. i } }
        end
        return { comp = col, props = {}, children = children }
      end
    end

    local function make_buf()
      local buf = vim.api.nvim_create_buf(false, true)
      local buflines = {}
      for i = 1, 12 do
        buflines[i] = "b" .. i
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, buflines)
      return buf
    end

    it("box writes never corrupt canvas highlight marks (gravity inversion)", function()
      -- A full-width hl'd label and an input SWAP rows: restore_box rewrites
      -- the input's OLD rows — now the label's row. A set_text replacement
      -- covering a mark's exact extent INVERTS it via gravity (start has
      -- right gravity, end doesn't): start lands at the edit end, end at the
      -- edit start, and the highlight silently disappears until the next
      -- repaint of that row.
      local function App(_, props)
        local label = { comp = text, props = { text = { { ("#"):rep(20), hl = "Search" } } } }
        local input = { comp = text_input, props = { height = 2 } }
        local children = props.swapped and { input, label } or { label, input }
        return { comp = col, props = {}, children = children }
      end
      local handle = mount.floating(App, { swapped = false }, { width = 20, height = 4 })

      local function search_marks()
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
          if m[4].hl_group == "Search" then
            out[#out + 1] = { row = m[2], col = m[3], end_row = m[4].end_row or m[2], end_col = m[4].end_col }
          end
        end
        return out
      end

      assert.same({ { row = 0, col = 0, end_row = 0, end_col = 20 } }, search_marks())

      handle.set_props({ swapped = true })
      assert.same({ { row = 2, col = 0, end_row = 2, end_col = 20 } }, search_marks())

      handle.unmount()
    end)

    it("box writes keep marks beside the box cell-faithful (byte-divergent mirror)", function()
      -- A mirror write can change the row's BYTE layout (multibyte widget
      -- content over single-byte canvas cells). Marks re-derived from the
      -- canvas ground truth after the write must be translated through CELLS
      -- onto the actual line, or every mark to the right of the box lands at
      -- a stale byte offset — highlights visibly shifted off their text.
      local row = { __host = "row" }
      local function App()
        return {
          comp = row,
          props = {},
          children = {
            { comp = text_input, props = { width = 10 } },
            { comp = text, props = { text = { { "TAG", hl = "Search" } } } },
          },
        }
      end
      local handle = mount.floating(App, {}, { width = 20, height = 1 })

      local function search_mark()
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
          if m[4].hl_group == "Search" then
            return { row = m[2], col = m[3], end_col = m[4].end_col }
          end
        end
      end

      -- canvas bytes: 10 single-byte cells of input interior, then TAG
      assert.same({ row = 0, col = 10, end_col = 13 }, search_mark())

      -- multibyte widget content: 3 cells, 9 bytes — the mirrored row's byte
      -- layout now diverges from the canvas ground truth
      local sub = subwin_of(handle)
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false, { "───" })
      vim.wait(500, function()
        return (lines_of(handle.bufnr)[1] or ""):find("───", 1, true) ~= nil
      end)

      -- TAG still starts at cell 10 = byte 9 + 7 + 1 → col 16 on the new line
      assert.same({ row = 0, col = 16, end_col = 19 }, search_mark())

      handle.unmount()
    end)

    it("mirrors the visible slice into the root canvas, padded to the box", function()
      local buf = make_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 6, height = 6 })

      local root = lines_of(handle.bufnr)
      assert.equal("b1    ", root[1])
      assert.equal("b2    ", root[2])
      assert.equal("b3    ", root[3])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("follows the widget's own scroll", function()
      local buf = make_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 6, height = 6 })
      local sub = subwin_of(handle)

      vim.api.nvim_win_call(sub, function()
        vim.fn.winrestview({ topline = 4, lnum = 4, col = 0 })
      end)
      handle.relayout()

      local root = lines_of(handle.bufnr)
      assert.equal("b4    ", root[1])
      assert.equal("b6    ", root[3])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("edits to the sub buffer refresh the mirror (coalesced)", function()
      local buf = make_buf()
      local handle = mount.floating(editor_app(buf), {}, { width = 6, height = 6 })

      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "EDITED" })
      vim.wait(200, function()
        return lines_of(handle.bufnr)[1] == "EDITED"
      end)
      assert.equal("EDITED", lines_of(handle.bufnr)[1])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("long lines truncate to the box width; tabs expand", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij", "\tx" })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 2, wrap = false } },
          },
        }
      end, {}, { width = 6, height = 4 })

      local root = lines_of(handle.bufnr)
      assert.equal("abcdef", root[1])
      -- default tabstop 8 clipped at 6 cells: all spaces
      assert.equal("      ", root[2])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a horizontally scrolled nowrap widget mirrors from leftcol", function()
      -- nowrap + leftcol: the float displays the slice starting at leftcol;
      -- the mirror (and its transcription map) must start there too.
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij", "0123456789" })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 2, wrap = false } },
          },
        }
      end, {}, { width = 6, height = 4 })
      local sub = subwin_of(handle)

      vim.api.nvim_win_call(sub, function()
        vim.fn.winrestview({ topline = 1, lnum = 1, col = 7, leftcol = 4 })
      end)
      handle.relayout()

      local root = lines_of(handle.bufnr)
      assert.equal("efghij", root[1])
      assert.equal("456789", root[2])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a wrapping raw_buffer mirrors wrapped screen rows, like the float shows", function()
      -- raw_buffer wraps by default: a 10-cell line in a 6-cell box occupies
      -- two display rows; the mirror must reproduce that, not truncate.
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij", "z" })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 3 } },
          },
        }
      end, {}, { width = 6, height = 4 })

      local root = lines_of(handle.bufnr)
      assert.equal("abcdef", root[1])
      assert.equal("ghij  ", root[2])
      assert.equal("z     ", root[3])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a text_input's seeded value is mirrored under its border", function()
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text_input, props = { style = { border = true }, value = "hi" } },
          },
        }
      end, {}, { width = 8, height = 4 })

      -- row 2 (1-based): │ + content + │
      local row = lines_of(handle.bufnr)[2]
      assert.truthy(row:find("hi", 1, true), "mirror missing: " .. row)

      handle.unmount()
    end)
  end)

  -- render="focus": the float exists but stays hidden until explicitly
  -- focused; the text mirror (plus transcribed highlights) is the view. The
  -- per-component prop is the experiment knob vs the default render="always"
  -- (float always shown; mirror invisible but keeps the region honest).
  describe("render policy", function()
    local function press(key)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
    end

    local function focus_app(buf)
      return function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = "head" } },
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 2, render = "focus", wrap = false } },
            { comp = text, props = { text = "tail" } },
          },
        }
      end
    end

    it("focus is the DEFAULT policy: an un-annotated widget's float hides until entered", function()
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text, props = { text = "head" } },
            { comp = text_input, props = { value = "hi", height = 1 } },
          },
        }
      end, {}, { width = 6, height = 3 })
      local sub = subwin_of(handle)

      assert.is_true(vim.api.nvim_win_get_config(sub).hide)
      assert.equal("hi    ", lines_of(handle.bufnr)[2])

      handle.unmount()
    end)

    it("the float stays hidden while unfocused; the mirror is the view", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })
      local sub = subwin_of(handle)

      assert.is_true(vim.api.nvim_win_get_config(sub).hide)
      assert.equal("b1    ", lines_of(handle.bufnr)[2])

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("<CR> entry reveals and focuses it; leaving hides it again", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })
      local sub = subwin_of(handle)

      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 })
      press("<CR>")
      assert.equal(sub, vim.api.nvim_get_current_win())
      assert.falsy(vim.api.nvim_win_get_config(sub).hide)

      vim.api.nvim_set_current_win(handle.winid)
      vim.wait(200, function()
        return vim.api.nvim_win_get_config(sub).hide == true
      end)
      assert.is_true(vim.api.nvim_win_get_config(sub).hide)

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("persistent extmark highlights transcribe onto the mirror", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local ns = vim.api.nvim_create_namespace("subwin_spec_hl")
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 2, hl_group = "ErrorMsg" })

      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })

      local found = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "ErrorMsg" then
          found[#found + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
        end
      end
      -- the widget's row 0 is root row 1 (below "head"), box starts at col 0
      assert.same({ { row = 1, col = 0, end_col = 2 } }, found)

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("regex syntax highlights transcribe onto the mirror", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("syntax match Constant /b2/")
      end)
      vim.b[buf].current_syntax = "subwin_spec" -- transcriber's "has syntax" contract

      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })

      local found = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "Constant" then
          found[#found + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
        end
      end
      assert.same({ { row = 2, col = 0, end_col = 2 } }, found)

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("render='always' does NOT transcribe highlights (mirror is invisible)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local ns = vim.api.nvim_create_namespace("subwin_spec_hl")
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 2, hl_group = "ErrorMsg" })

      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 2, wrap = false, render = "always" } },
          },
        }
      end, {}, { width = 6, height = 4 })

      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
        assert.truthy(m[4].hl_group ~= "ErrorMsg", "always-policy mirror transcribed a highlight")
      end

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- Every flush rewrites the whole canvas (nvim_buf_set_lines 0,-1), which
    -- RELOCATES existing extmarks out of the widget's box — a box-ranged
    -- namespace clear misses them, and transcription marks accumulate
    -- (hundreds per flush on the docs homepage, with linearly growing frame
    -- times). The clear must cover the whole per-entry namespace.
    it("transcribed highlights do not accumulate across flushes", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local ns = vim.api.nvim_create_namespace("subwin_spec_hl")
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 2, hl_group = "ErrorMsg" })
      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })

      handle.relayout()
      handle.relayout()

      local found = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "ErrorMsg" then
          found = found + 1
        end
      end
      assert.equal(1, found)

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- A pure scroll frame changes only where floats sit on the window grid;
    -- the widget's view, its buffer and the canvas cells are all untouched —
    -- so the mirror + transcription extraction must be REUSED, not redone
    -- (it is the dominant per-frame cost with syntax on: ~3ms per widget).
    it("a pure scroll resync reuses the extraction: no writes, stable marks", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      local ns = vim.api.nvim_create_namespace("subwin_spec_hl")
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 2, hl_group = "ErrorMsg" })
      local function App()
        local children = {
          { comp = text, props = { text = "head" } },
          { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 2, render = "focus", wrap = false } },
        }
        for i = 1, 6 do
          children[#children + 1] = { comp = text, props = { text = "f" .. i } }
        end
        return { comp = col, props = {}, children = children }
      end
      local handle = mount.floating(App, {}, { width = 6, height = 4, mode = "scroll" })

      local function mark_of()
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
          if m[4].hl_group == "ErrorMsg" then
            return m[1], m[2]
          end
        end
      end
      local id0 = mark_of()
      local tick0 = vim.api.nvim_buf_get_changedtick(handle.bufnr)

      -- scroll without a re-render/flush: the WinScrolled path alone
      scroll_root(handle, 2)
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })

      assert.equal(tick0, vim.api.nvim_buf_get_changedtick(handle.bufnr))
      local id1, row1 = mark_of()
      assert.equal(id0, id1)
      assert.equal(1, row1) -- still at the widget's buffer row, untouched

      -- but an actual view change (the widget's own scroll) re-extracts
      vim.api.nvim_win_call(subwin_of(handle), function()
        vim.fn.winrestview({ topline = 2, lnum = 2, col = 0 })
      end)
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
      assert.equal("b2    ", lines_of(handle.bufnr)[2]) -- mirror followed
      assert.is_nil((mark_of())) -- line 1 (and its mark) scrolled out of view

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- Guards the syntax-run cache: an edit must invalidate cached runs.
    it("editing the sub buffer refreshes transcribed syntax highlights", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b1", "b2" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("syntax match Constant /b2/")
      end)
      vim.b[buf].current_syntax = "subwin_spec"
      local handle = mount.floating(focus_app(buf), {}, { width = 6, height = 4 })

      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "x b2" })
      vim.wait(200, function()
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
          if m[4].hl_group == "Constant" and m[3] == 2 then
            return true
          end
        end
        return false
      end)

      local found = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "Constant" then
          found[#found + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
        end
      end
      assert.same({ { row = 2, col = 2, end_col = 4 } }, found)

      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
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

  -- Click-to-insert: a pointer user may have no keyboard at all (on mobile
  -- the OSK only appears in insert-ish modes), so clicking a text field means
  -- "edit it" — the click path (<LeftRelease>) enters the widget IN INSERT
  -- MODE, GUI-style. <CR> keeps today's normal-mode entry: whoever pressed it
  -- has a keyboard and `i` is right there. text_input defaults on, raw_buffer
  -- (arbitrary content, often read-only) defaults off; `insert_on_click`
  -- overrides either way.
  --
  -- Real clicks can't be synthesized headless (no UI grid = mouse_find_win
  -- can't resolve floats), so like interact_spec these park the cursor where
  -- the click's press would and fire <LeftRelease>; keys batched behind it
  -- type into whatever mode the click landed in — insert types text, normal
  -- runs operators — which is the observable the specs pin. (feedkeys "x"
  -- leaves insert mode when the batch drains, so live mode is never probed.)
  describe("click to insert", function()
    local function input_app(props)
      return function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = text_input, props = props },
          },
        }
      end
    end

    -- Park the root cursor at display cell `x` of row 1 and click+type.
    local function click_then(handle, x, keys)
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 1, x })
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<LeftRelease>" .. keys, true, false, true),
        "xt",
        false
      )
    end

    local function sub_line(handle)
      local sub = subwin_of(handle)
      assert.is_not_nil(sub, "no subwindow float")
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, 1, false)[1]
    end

    it("a click on a text_input enters it in insert mode at the clicked cell", function()
      local handle = mount.floating(input_app({ value = "hi" }), {}, { width = 8, height = 3 })
      click_then(handle, 0, "yo!")
      assert.equal("yo!hi", sub_line(handle)) -- typed as text, before the clicked char
      handle.unmount()
    end)

    it("<CR> still enters in normal mode (keyboard users have `i`)", function()
      local handle = mount.floating(input_app({ value = "hi" }), {}, { width = 8, height = 3 })
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<CR>rY", true, false, true),
        "xt",
        false
      )
      assert.equal("Yi", sub_line(handle)) -- rY ran as a normal-mode operator
      handle.unmount()
    end)

    it("a click past the end of the line appends, GUI-caret style", function()
      local handle = mount.floating(input_app({ value = "hi" }), {}, { width = 8, height = 3 })
      click_then(handle, 4, "!")
      assert.equal("hi!", sub_line(handle))
      handle.unmount()
    end)

    it("insert_on_click = false keeps the click in normal mode", function()
      local handle =
        mount.floating(input_app({ value = "hi", insert_on_click = false }), {}, { width = 8, height = 3 })
      click_then(handle, 0, "rY")
      assert.equal("Yi", sub_line(handle))
      handle.unmount()
    end)

    it("raw_buffer clicks stay in normal mode unless opted in", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi" })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            { comp = { __host = "raw_buffer" }, props = { bufnr = buf, height = 1, wrap = false } },
          },
        }
      end, {}, { width = 8, height = 3 })
      click_then(handle, 0, "rY")
      assert.equal("Yi", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("raw_buffer with insert_on_click = true inserts", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi" })
      local handle = mount.floating(function()
        return {
          comp = col,
          props = {},
          children = {
            {
              comp = { __host = "raw_buffer" },
              props = { bufnr = buf, height = 1, wrap = false, insert_on_click = true },
            },
          },
        }
      end, {}, { width = 8, height = 3 })
      click_then(handle, 0, "rY")
      assert.equal("rYhi", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]) -- typed, not operated
      handle.unmount()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a click on an already-visible, focused float also enters insert", function()
      -- render="always" floats take real clicks natively (core focuses the
      -- float); the float-buffer <LeftRelease> map is that path's half
      local handle =
        mount.floating(input_app({ value = "hi", render = "always" }), {}, { width = 8, height = 3 })
      -- get into the float in normal mode first, the keyboard way
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
      local sub = subwin_of(handle)
      assert.equal(sub, vim.api.nvim_get_current_win())
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<LeftRelease>x", true, false, true),
        "xt",
        false
      )
      assert.equal("xhi", sub_line(handle))
      handle.unmount()
    end)
  end)
end)
