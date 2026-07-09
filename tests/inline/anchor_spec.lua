-- Cursor anchoring across relayout (requests.md weave bug: "resizing the window
-- horizontally … sends your cursor haywire, and we lose our position … I would
-- rather the transcript cursor stays pinned"). A scroll-mode surface keeps the
-- cursor on the SAME logical entry when the tree re-lays-out beneath it — not on
-- the same absolute buffer line.
--
-- The trigger is a COUNT-CHANGING relayout: a width shrink rewraps every
-- paragraph, so the host's splice replaces the span the cursor sits in and the
-- cursor is left on a row that now holds a DIFFERENT entry's wrapped tail. (A
-- pure insert-above is handled by nvim's own set_lines row-adjust — the head/
-- tail diff keeps it a clean insert — so it is NOT the bug.) Because
-- reconciliation is positional, the anchor keys on a stable `key` prop (the
-- entry's identity), not fiber identity.
--
-- Anchoring is opt-out per surface (`anchor = false`). It is NOT gated to focus:
-- an unfocused surface still holds its VIEW across a relayout — it pins the entry
-- at the reference row (the cursor's entry when the cursor is on-screen, else the
-- top-visible entry) by topline, WITHOUT moving the cursor, so an app's own
-- follow-to-bottom keeps ownership of the cursor. A FOCUSED surface additionally
-- moves the cursor. The topline-held / no-visual-jump half is eyeballed in the
-- PTY repro; here we assert the entry lands back under the reference row.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- wrapping paragraphs so a width change alters line counts; each carries its
-- stable identity as `key`.
local function App(_, props)
  local kids = {}
  for _, it in ipairs(props.items) do
    kids[#kids + 1] = { comp = ui.paragraph, key = it.id, props = { text = it.text } }
  end
  return { comp = ui.col, props = {}, children = kids }
end

-- Same, but WITHOUT keys — the common case (the scroll example): a resize must
-- still pin the cursor to the entry it is on. No reconciliation happens on a
-- pure relayout, so the fiber identity is stable and is the anchor's fallback.
local function KeylessApp(_, props)
  local kids = {}
  for _, it in ipairs(props.items) do
    kids[#kids + 1] = { comp = ui.paragraph, props = { text = it.text } }
  end
  return { comp = ui.col, props = {}, children = kids }
end

local function seed(n)
  local out = {}
  for i = 1, n do
    out[i] = { id = i, text = ("ENTRY%d "):format(i) .. string.rep("word ", 12) }
  end
  return out
end

local function row_of(handle, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return i
    end
  end
end

local function cursor_line(handle)
  local r = vim.api.nvim_win_get_cursor(handle.winid)[1]
  return vim.api.nvim_buf_get_lines(handle.bufnr, r - 1, r, false)[1] or ""
end

local function topline(handle)
  return vim.api.nvim_win_call(handle.winid, function()
    return vim.fn.winsaveview().topline
  end)
end

-- Focus the surface and park the cursor on the first row of `needle`'s entry.
local function focus_on(handle, needle)
  vim.api.nvim_set_current_win(handle.winid)
  local r = assert(row_of(handle, needle), "entry not found: " .. needle)
  vim.api.nvim_win_set_cursor(handle.winid, { r, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

local function mount_app(anchor)
  vim.o.columns = 80
  vim.o.lines = 30
  return mount.floating(App, { items = seed(9) }, { height = 12, mode = "scroll", anchor = anchor })
end

local function resize(handle, cols)
  vim.o.columns = cols
  handle.relayout()
end

describe("inline cursor anchor", function()
  -- these tests resize the editor; don't leak that to later specs
  local orig_cols, orig_lines
  before_each(function()
    orig_cols, orig_lines = vim.o.columns, vim.o.lines
  end)
  after_each(function()
    vim.o.columns, vim.o.lines = orig_cols, orig_lines
  end)

  -- screen offset = how many rows below the top of the viewport the cursor sits
  local function screen_offset(handle)
    local pos = vim.api.nvim_win_get_cursor(handle.winid)[1]
    return pos - topline(handle)
  end

  it("keeps the cursor on the same keyed entry across a width resize", function()
    local handle = mount_app()
    focus_on(handle, "ENTRY5")
    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true))
    local off = screen_offset(handle)

    resize(handle, 40) -- rewraps everything → count-changing splice

    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true), "cursor left its logical entry on resize")
    -- and the entry holds its screen row, so the view doesn't visibly jump
    assert.equal(off, screen_offset(handle), "content jumped — screen row not held across resize")
    handle.unmount()
  end)

  it("pins the cursor across resize even without keys (fiber fallback)", function()
    vim.o.columns = 80
    vim.o.lines = 30
    local handle = mount.floating(KeylessApp, { items = seed(9) }, { height = 12, mode = "scroll" })
    focus_on(handle, "ENTRY5")
    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true))

    resize(handle, 40) -- the scroll-example scenario: rewrap, no keys anywhere

    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true), "keyless cursor swam on resize")
    handle.unmount()
  end)

  it("pins the cursor over a split-mounted scroll surface on a pane resize", function()
    -- exactly the inline_scroll example: mount.split, keyless, resize the pane
    vim.o.columns = 120
    vim.o.lines = 40
    local handle = mount.split(KeylessApp, { items = seed(9) }, {
      split = { direction = "vertical", position = "left", size = 60 },
      mode = "scroll",
    })
    handle.focus()
    focus_on(handle, "ENTRY5")
    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true))

    vim.api.nvim_win_set_width(handle.host_winid, 24) -- shrink the pane → rewrap
    handle.relayout()

    assert.truthy(cursor_line(handle):find("ENTRY5", 1, true), "cursor swam on a split pane resize")
    handle.unmount()
  end)

  it("anchor = false leaves the cursor on the absolute row (loses the entry)", function()
    local handle = mount_app(false)
    focus_on(handle, "ENTRY5")
    local before = vim.api.nvim_win_get_cursor(handle.winid)[1]

    resize(handle, 40)

    assert.equal(before, vim.api.nvim_win_get_cursor(handle.winid)[1], "row should not move without anchoring")
    assert.falsy(cursor_line(handle):find("ENTRY5", 1, true), "without anchoring the row now holds other content")
    handle.unmount()
  end)

  it("holds an UNFOCUSED surface's view across a resize (pins the entry, not the cursor)", function()
    -- The transcript case: focus is on the parent, but a resize must not make the
    -- unfocused transcript swim. We hold the reference entry's screen row by
    -- topline and leave the cursor alone (the app's follow owns the cursor).
    local base = vim.api.nvim_get_current_win()
    vim.o.columns = 80
    vim.o.lines = 30
    local handle = mount.floating(App, { items = seed(20) }, { height = 8, mode = "scroll" })
    -- scroll it (as a wheel scroll would) so ENTRY8 sits at the top of the view,
    -- the cursor riding along on-screen; the surface stays UNFOCUSED throughout
    local r = assert(row_of(handle, "ENTRY8"))
    vim.api.nvim_win_set_cursor(handle.winid, { r, 0 })
    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = r, lnum = r, col = 0 })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
    assert.is_true(vim.api.nvim_get_current_win() == base, "surface must be unfocused for this test")
    local cur_before = vim.api.nvim_win_get_cursor(handle.winid)[1]

    resize(handle, 40) -- rewrap while unfocused

    local tl = topline(handle)
    local top = vim.api.nvim_buf_get_lines(handle.bufnr, tl - 1, tl, false)[1] or ""
    assert.truthy(top:find("ENTRY8", 1, true), "unfocused view swam: ENTRY8 not held at the top")
    assert.equal(
      cur_before,
      vim.api.nvim_win_get_cursor(handle.winid)[1],
      "unfocused anchoring must not move the cursor (the app's follow owns it)"
    )
    handle.unmount()
  end)

  it("anchor = false does not hold an unfocused view either", function()
    vim.o.columns = 80
    vim.o.lines = 30
    local handle = mount.floating(App, { items = seed(20) }, { height = 8, mode = "scroll", anchor = false })
    local r = assert(row_of(handle, "ENTRY8"))
    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = r, lnum = r, col = 0 })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })

    resize(handle, 40)

    local tl = topline(handle)
    local top = vim.api.nvim_buf_get_lines(handle.bufnr, tl - 1, tl, false)[1] or ""
    assert.falsy(top:find("ENTRY8", 1, true), "anchor=false must not hold the unfocused view")
    handle.unmount()
  end)

  it("pins the cursor in a NESTED container across a resize (the weave transcript shape)", function()
    -- the transcript is a ui.container (its own buffer/float) with keyless
    -- wrapping entries; a resize gives the container a FULL ("all") repaint,
    -- which reanchor must act on (it arrives as nil damage, not a range).
    local cont_win
    local function App(_, props)
      local kids = {}
      for _, it in ipairs(props.items) do
        kids[#kids + 1] = { comp = ui.paragraph, props = { text = it.text } }
      end
      return {
        comp = ui.container,
        props = { grow = 1, on_create = function(_, w) cont_win = w end },
        children = kids,
      }
    end
    vim.o.columns = 80
    vim.o.lines = 24
    local handle = mount.floating(App, { items = seed(9) }, { height = 14, mode = "fixed" })
    assert.is_true(type(cont_win) == "number", "container float not created")
    local cbuf = vim.api.nvim_win_get_buf(cont_win)

    local function crow(needle)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
        if l:find(needle, 1, true) then
          return i
        end
      end
    end
    vim.api.nvim_set_current_win(cont_win) -- the container's own interact owns its anchor
    local r = assert(crow("ENTRY5"), "ENTRY5 not found")
    vim.api.nvim_win_set_cursor(cont_win, { r, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = cbuf })

    vim.o.columns = 44 -- narrower editor → container rewraps (full repaint)
    handle.relayout()

    local cr = vim.api.nvim_win_get_cursor(cont_win)[1]
    local line = vim.api.nvim_buf_get_lines(cbuf, cr - 1, cr, false)[1] or ""
    assert.truthy(line:find("ENTRY5", 1, true), "nested-container cursor swam on resize")
    handle.unmount()
  end)

  it("does not fight a wheel scroll: a re-render keeps the scrolled view", function()
    -- a tall keyless scroll surface whose header changes on re-render
    local function TallApp(_, props)
      local kids = { { comp = ui.label, props = { text = "HEADER " .. (props.n or 0) } } }
      for i = 1, 40 do
        kids[#kids + 1] = { comp = ui.label, props = { text = "line " .. i } }
      end
      return { comp = ui.col, props = {}, children = kids }
    end
    vim.o.columns = 60
    vim.o.lines = 20
    local handle = mount.floating(TallApp, { n = 0 }, { width = 30, height = 10, mode = "scroll" })
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })

    -- wheel scroll down (view moves, cursor stays visible → WinScrolled, no CursorMoved)
    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = 9, lnum = 12, col = 0 })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })

    -- an unrelated re-render lands (animation / streaming / counter) — a damage flush
    handle.set_props({ n = 1 })

    local tl = topline(handle)
    assert.is_true(tl >= 8, "the anchor snapped the scroll back (topline " .. tl .. ")")
    handle.unmount()
  end)
end)
