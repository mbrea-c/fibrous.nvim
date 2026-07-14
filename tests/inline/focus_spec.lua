-- Focus traversal between the root buffer and subwindow floats (tracker "NEW
-- UI HOST" task 7; explicit-focus rework). Subwindows never capture the
-- cursor: hjkl glides across their region like any other cells. Focus is
-- always an explicit act:
--
--   in   <CR> (or a click) with the root cursor anywhere in the widget's rect
--        focuses its float at the corresponding cell; i/I/a/A/o/O focus it
--        AND replay the key inside, so "type here" costs one keystroke
--   out  h/j/k/l at the input buffer's edge exit to the root buffer adjacent
--        to the widget; <Esc> pops focus in place; <C-d>/<C-u> hand focus
--        back to the root and scroll it (page motions are never trapped).
--        <C-w> is NOT an exit: it acts on the host pane (see below)

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
    props = { style = { padding = { x = 1 } } },
    children = {
      { comp = ui.label, props = { text = "head" } },
      { comp = ui.text_input, props = { value = "abcdef", height = 1 } },
      { comp = ui.label, props = { text = "tail" } },
    },
  }
end

describe("inline.focus", function()
  it("moving the root cursor across an input region does NOT steal focus", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 }) -- the input row, cell 3
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })

    -- the cursor glides over the widget; no capture
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(handle.winid))
    handle.unmount()
  end)

  it("<CR> over the input focuses its float at the corresponding cell", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    press("<CR>")

    assert.equal(sub, vim.api.nvim_get_current_win())
    -- content box starts at x=1, so cell 3 is col 2 inside the input
    assert.same({ 1, 2 }, vim.api.nvim_win_get_cursor(sub))
    handle.unmount()
  end)

  it("a click over the input focuses it too (<LeftRelease> shares the activate path)", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 })
    press("<LeftRelease>")

    assert.equal(sub, vim.api.nvim_get_current_win())
    handle.unmount()
  end)

  it("i over the input inserts into the float's buffer at that cell", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 })
    -- one batch, like typing: focus the float AND insert before its cell 2
    press("iXY<Esc>")

    assert.equal(sub, vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "abXYcdef" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    handle.unmount()
  end)

  it("a over the input appends after that cell", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 })
    press("aZ<Esc>")

    assert.equal(sub, vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "abcZdef" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    handle.unmount()
  end)

  it("v over a subbuffer focuses it and starts the visual selection inside the float", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 }) -- over the input, cell 3 → input "c"
    press("v")

    -- focus crossed into the float and we are in visual mode there…
    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.equal("v", vim.api.nvim_get_mode().mode)
    -- …selecting to end-of-line and yanking grabs REAL sub-buffer text
    press("$y")
    assert.equal("cdef", vim.fn.getreg('"'))
    handle.unmount()
  end)

  it("v away from any subbuffer stays visual in the parent", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 }) -- on "head", no widget
    press("v")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.equal("v", vim.api.nvim_get_mode().mode)
    press("<Esc>")
    handle.unmount()
  end)

  it("dd over an unfocused editable subbuffer focuses it and deletes the line", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 }) -- over the input
    press("dd")

    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.same({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    handle.unmount()
  end)

  it("x over an unfocused editable subbuffer focuses it and deletes the char there", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 }) -- input cell 2 = "c"
    press("x")

    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.same({ "abdef" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    handle.unmount()
  end)

  it("an operator away from an editable widget is a native no-op on the root", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 }) -- on "head", no widget
    press("dd") -- native on the unmodifiable root: E21, no focus change

    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ "abcdef" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    handle.unmount()
  end)

  it("an operator over a NON-editable subwindow (container) does not focus it", function()
    local function ContainerApp()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = { height = 2 },
            children = {
              { comp = ui.label, props = { text = "row1" } },
              { comp = ui.label, props = { text = "row2" } },
            },
          },
        },
      }
    end
    local handle = mount.floating(ContainerApp, {}, { width = 12, height = 4 })
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 }) -- over the container region
    press("dd")
    -- a container is not a text-edit buffer: focus stays on the parent
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    handle.unmount()
  end)

  it("<CR> on a border cell enters, clamped into the content box", function()
    local function App()
      return {
        comp = ui.col,
        props = { style = { padding = { x = 1 } } },
        children = {
          { comp = ui.label, props = { text = "head" } },
          { comp = ui.text_input, props = { style = { border = true }, value = "abcdef" } },
        },
      }
    end
    -- rows (0-based): 0 head; 1 top border; 2 content; 3 bottom border
    local handle = mount.floating(App, {}, { width = 12, height = 6 })
    local sub = subwin_of(handle)

    -- park on the top border row above content cell 3 (byte 4: 3-byte ╭ + 2 ─)
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 4 })
    press("<CR>")
    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(sub))

    handle.unmount()
  end)

  it("insert keys away from any widget do not enter one", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 }) -- on "head"
    press("iXY<Esc>") -- native replay on the unmodifiable root: E21, no effect

    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ "abcdef" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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

  it("<Esc> in a focused subwindow (normal mode) pops focus back to the parent", function()
    local handle = mount.floating(PaddedApp, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle)

    -- focus the input in NORMAL mode (via <CR>, not an insert key)
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 3 })
    press("<CR>")
    assert.equal(sub, vim.api.nvim_get_current_win())

    -- <Esc> leaves the widget for the parent, landing on the widget's own cell
    press("<Esc>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.equal(2, vim.api.nvim_win_get_cursor(handle.winid)[1]) -- back on the input row
    handle.unmount()
  end)

  it("exits from a bordered input land ON the border cell, not past it", function()
    -- Entry crosses the border one keypress at a time (the border rows/cols
    -- are ordinary root cells), so exits must be symmetric: one step out of
    -- the content box is the border cell, not the far side of the box.
    local function App()
      return {
        comp = ui.col,
        props = { style = { padding = { x = 1 } } },
        children = {
          { comp = ui.label, props = { text = "head" } },
          -- no explicit height: `height` sizes the BORDER box, and a bordered
          -- input needs its default single content row
          { comp = ui.text_input, props = { style = { border = true }, value = "abcdef" } },
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

  -- requests.md: a fibrous mount should act as ONE window, however many
  -- floats implement it. <Esc> pops focus and edge h/j/k/l steps out, so
  -- <C-w> is reserved for real window work: it acts on the HOST pane from
  -- any depth of the subwindow hierarchy.
  it("<C-w> motions act on the HOST pane, not the float stack", function()
    vim.cmd("tabnew")
    local left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    local pane = vim.api.nvim_get_current_win()

    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          { comp = ui.text_input, props = { value = "l1\nl2", height = 2 } },
        },
      }
    end
    local handle = mount.window(App, {}, { winid = pane })
    local sub = subwin_of(handle)

    -- from the focused input, <C-w>h moves as if pressed in the pane: to the
    -- LEFT window — not to the root float, not trapped in the stack
    vim.api.nvim_set_current_win(sub)
    press("<C-w>h")
    assert.equal(left, vim.api.nvim_get_current_win())

    -- a command that focuses no other window (<C-w>=) hands focus back to
    -- the app instead of stranding it on the blank backing pane
    vim.api.nvim_set_current_win(sub)
    press("<C-w>=")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())

    handle.unmount()
    vim.cmd("tabclose")
  end)

  it("<C-w> still reaches the host pane from a NESTED subwindow", function()
    vim.cmd("tabnew")
    local left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    local pane = vim.api.nvim_get_current_win()

    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = { height = 3 },
            children = {
              { comp = ui.text_input, props = { value = "deep", height = 1 } },
            },
          },
        },
      }
    end
    local handle = mount.window(App, {}, { winid = pane })
    local container = subwin_of(handle)
    assert.is_not_nil(container)
    -- the input's float is anchored to the CONTAINER's float, one level down
    local inner
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "win" and cfg.win == container then
        inner = win
      end
    end
    assert.is_not_nil(inner)

    vim.api.nvim_set_current_win(inner)
    press("<C-w>h")
    assert.equal(left, vim.api.nvim_get_current_win())

    handle.unmount()
    vim.cmd("tabclose")
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

  -- A focused widget can be unmounted out from under its own focus: the TODO
  -- pattern — on_submit inserts a sibling BEFORE the input, the positional
  -- reconciler recreates the input at the shifted index — destroys the float
  -- the user is typing in. Without a guard, nvim drops focus into whatever
  -- window is previous, with insert mode still active in the unmodifiable
  -- root ("insert mode in the air").
  it("unmounting the focused widget leaves insert mode and refocuses the root", function()
    local function App(ctx)
      local items = ctx.use_state({ "item a" })
      local children = {}
      for _, it in ipairs(items.get()) do
        children[#children + 1] = { comp = ui.label, props = { text = it } }
      end
      children[#children + 1] = {
        comp = ui.text_input,
        props = {
          height = 1,
          on_submit = function(value)
            local next_items = vim.deepcopy(items.get())
            next_items[#next_items + 1] = value
            items.set(next_items)
            -- land the re-render (and the input's destroy) while insert mode
            -- is still active — a live user's <CR> pauses here too
            vim.wait(100, function()
              return false
            end)
          end,
        },
      }
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 5 })

    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 }) -- the input row
    -- one batch: enter, type, <Esc> back to normal, submit (normal-mode <CR>) —
    -- the submit destroys the focused input (positional reconciliation shifts it)
    -- so focus must return cleanly to the root; then "gg" distinguishes the
    -- outcomes: stuck on the dead float it mangles things, back on the root it is
    -- a plain motion to the top
    press("ifoo<Esc><CR>gg")

    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.equal("n", vim.api.nvim_get_mode().mode)
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.winid))
    -- the submit itself landed: the new item is on the page
    local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
    assert.is_not_nil(table.concat(lines, "\n"):find("foo", 1, true))

    handle.unmount()
  end)
end)
