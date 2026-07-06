-- ui.container: the multi-container boundary. A container is a subwindow leaf
-- in its parent's tree (border/background inline, like text_input), but its
-- CHILDREN lay out into the container's own buffer — painted, spliced and
-- damage-tracked by the same host — shown in an always-on float over the
-- boundary box. One fiber tree, N buffers: hooks, memoization and set_state
-- flow through the boundary with no portal glue. The float is a real window,
-- so the container scrolls natively; its own subwindows (text inputs, deeper
-- containers) anchor to it recursively.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- All floats anchored to `winid`, in creation order.
local function subwins_of(winid)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "win" and cfg.win == winid then
      out[#out + 1] = { winid = win, cfg = cfg }
    end
  end
  return out
end

local function subwin_of(winid)
  local subs = subwins_of(winid)
  return subs[1] and subs[1].winid, subs[1] and subs[1].cfg
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function trimmed(bufnr)
  return vim.tbl_map(function(l)
    return (l:gsub("%s+$", ""))
  end, buf_lines(bufnr))
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

describe("inline.container", function()
  it("renders children into its own buffer, shown in a float over the boundary", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.label, props = { text = "alpha" } },
              { comp = ui.label, props = { text = "beta" } },
            },
          },
          { comp = ui.label, props = { text = "tail" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 6 })

    local sub, cfg = subwin_of(handle.winid)
    assert.is_not_nil(sub)
    -- auto-sized: the boundary is exactly the inner content's height, placed
    -- under the head label
    assert.equal(1, cfg.row)
    assert.equal(2, cfg.height)

    -- the float shows the container's OWN buffer, painted by the same host
    local cbuf = vim.api.nvim_win_get_buf(sub)
    assert.is_true(cbuf ~= handle.bufnr)
    assert.same({ "alpha", "beta" }, trimmed(cbuf))

    -- the boundary region in the root buffer mirrors the content (honest
    -- text under a gliding cursor), and the siblings sit around it
    assert.same({ "head", "alpha", "beta", "tail", "", "" }, trimmed(handle.bufnr))

    handle.unmount()
  end)

  it("an explicit height is a viewport: the buffer grows, the float doesn't", function()
    local function App()
      local rows = {}
      for i = 1, 4 do
        rows[i] = { comp = ui.label, props = { text = "row " .. i } }
      end
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.container, props = { height = 2 }, children = rows },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })

    local sub, cfg = subwin_of(handle.winid)
    assert.equal(2, cfg.height)
    -- scroll mode inside: all four rows exist in the buffer, the float is a
    -- native viewport over them
    assert.same({ "row 1", "row 2", "row 3", "row 4" }, trimmed(vim.api.nvim_win_get_buf(sub)))

    handle.unmount()
  end)

  it('mode = "fixed" lays the content out at exactly the viewport height', function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            -- justify only bites when the inner layout SEES the viewport
            -- height — in scroll mode there is no leftover space to justify
            props = { height = 3, mode = "fixed", justify = "end" },
            children = {
              { comp = ui.label, props = { text = "last" } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3 })

    local sub = subwin_of(handle.winid)
    assert.same({ "", "", "last" }, trimmed(vim.api.nvim_win_get_buf(sub)))

    handle.unmount()
  end)

  it("scrolling a container repositions the floats inside it", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = { height = 2 },
            children = {
              { comp = ui.label, props = { text = "aa" } },
              { comp = ui.label, props = { text = "bb" } },
              { comp = ui.text_input, props = { value = "", height = 1, render = "always" } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 2 })
    local csub = subwin_of(handle.winid)

    -- the input sits below the 2-row viewport: its float is hidden
    local isub, icfg = subwin_of(csub)
    assert.is_true(icfg.hide)

    -- scroll the container so rows 2-3 show; the resync (same code path as
    -- the WinScrolled autocmd) reveals the input at its visible offset
    vim.api.nvim_win_call(csub, function()
      vim.fn.winrestview({ topline = 2, lnum = 2, col = 0 })
    end)
    handle.relayout()
    icfg = vim.api.nvim_win_get_config(isub)
    assert.is_false(icfg.hide)
    assert.equal(1, icfg.row) -- inner row 2, one row scrolled off

    handle.unmount()
  end)

  it("updates flow through the one fiber tree; unrelated updates don't touch the container buffer", function()
    local function App(_, props)
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = props.head or "head" } },
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.label, props = { text = props.msg or "one" } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })
    local sub = subwin_of(handle.winid)
    local cbuf = vim.api.nvim_win_get_buf(sub)
    assert.same({ "one" }, trimmed(cbuf))

    -- a prop change re-renders straight through the boundary — same buffer,
    -- new content
    handle.set_props({ msg = "two" })
    assert.equal(cbuf, vim.api.nvim_win_get_buf((subwin_of(handle.winid))))
    assert.same({ "two" }, trimmed(cbuf))

    -- an update that only touches the ROOT target must not write the
    -- container's buffer at all (per-target damage)
    local tick = vim.api.nvim_buf_get_changedtick(cbuf)
    handle.set_props({ msg = "two", head = "HEAD" })
    assert.same({ "HEAD", "two", "", "" }, trimmed(handle.bufnr))
    assert.equal(tick, vim.api.nvim_buf_get_changedtick(cbuf))

    handle.unmount()
  end)

  it("a text_input inside a container works end to end", function()
    local got, submitted
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = { height = 3 },
            children = {
              { comp = ui.label, props = { text = "ask:" } },
              {
                comp = ui.text_input,
                props = {
                  value = "",
                  height = 1,
                  -- always-shown so the float's geometry is asserted below
                  -- (render="focus" floats keep their creation config while
                  -- hidden)
                  render = "always",
                  on_change = function(v)
                    got = v
                  end,
                  on_submit = function(v)
                    submitted = v
                  end,
                },
              },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })

    -- the input's float anchors to the CONTAINER's float, not the root
    local csub = subwin_of(handle.winid)
    local isub, icfg = subwin_of(csub)
    assert.is_not_nil(isub)
    assert.equal(1, icfg.row) -- under the "ask:" label, in container coords

    vim.api.nvim_set_current_win(isub)
    press("ihello")
    vim.wait(200, function()
      return got ~= nil
    end)
    assert.equal("hello", got)
    press("<Esc><CR>")
    assert.equal("hello", submitted)

    handle.unmount()
  end)

  it("focus hops: <CR> enters the container, <CR> again enters its input, edges exit level by level", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.label, props = { text = "inner" } },
              { comp = ui.text_input, props = { value = "seed", height = 1 } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })
    local csub = subwin_of(handle.winid)
    local isub = subwin_of(csub)

    -- <CR> on the boundary (root row 2, 1-based) focuses the container float
    handle.focus()
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 })
    press("<CR>")
    assert.equal(csub, vim.api.nvim_get_current_win())

    -- inside, <CR> over the input row hops one level deeper
    vim.api.nvim_win_set_cursor(csub, { 2, 0 })
    press("<CR>")
    assert.equal(isub, vim.api.nvim_get_current_win())

    -- k at the input's top edge exits into the container buffer...
    press("k")
    assert.equal(csub, vim.api.nvim_get_current_win())
    -- ...and k at the container's top edge exits to the root, on "head"
    vim.api.nvim_win_set_cursor(csub, { 1, 0 })
    press("k")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.equal(1, vim.api.nvim_win_get_cursor(handle.winid)[1])

    handle.unmount()
  end)

  it("<CR> over a button inside a container presses it AND focuses the container (one press)", function()
    local pressed = 0
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = {},
            children = {
              {
                comp = ui.button,
                props = {
                  label = "go",
                  on_press = function()
                    pressed = pressed + 1
                  end,
                },
              },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 4 })
    local csub = subwin_of(handle.winid)

    -- focus on the ROOT, cursor navigated over the button (container's first
    -- row is root line 2; `[ go ]` starts at col 0, so col 2 is inside it)
    handle.focus()
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 2 })

    press("<CR>")
    -- one press: the button fired, and focus crossed into the container
    assert.equal(1, pressed)
    assert.equal(csub, vim.api.nvim_get_current_win())

    handle.unmount()
  end)

  it("hover reaches into an UNFOCUSED container: the root cursor over a button highlights it, focus stays on the root", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.button, props = { label = "go", on_press = function() end } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 4 })
    local csub = subwin_of(handle.winid)
    local cbuf = vim.api.nvim_win_get_buf(csub)

    -- a button hovers structurally-adjacent via its themed fill hl overlay
    local function hover_marks(bufnr)
      local n = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "FibrousButtonHover" then
          n = n + 1
        end
      end
      return n
    end

    -- root focused, cursor NOT over the button yet (on the head label)
    handle.focus()
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.equal(0, hover_marks(cbuf))

    -- navigate the cursor over the button (container's first row = root line 2)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 2 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    -- the button is highlighted in the CONTAINER's buffer, focus still the root
    assert.is_true(hover_marks(cbuf) > 0)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())

    -- move off the button (back to the head label) → the container hover clears
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.equal(0, hover_marks(cbuf))

    handle.unmount()
  end)

  it("dead space past a container's content never hovers or activates its last line", function()
    -- container box is TALLER than its content (rows below the last line are
    -- blank padding). A parent cursor over that dead space must NOT clamp onto
    -- the last content line — hover and <CR> there do nothing, even though the
    -- last line holds a button.
    local pressed = 0
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "top" } },
          {
            comp = ui.container,
            props = { height = 4 }, -- 2 content rows + 2 blank padding rows
            children = {
              { comp = ui.label, props = { text = "head" } },
              {
                comp = ui.button,
                props = {
                  label = "go",
                  on_press = function()
                    pressed = pressed + 1
                  end,
                },
              },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 6 })
    local csub = subwin_of(handle.winid)
    local cbuf = vim.api.nvim_win_get_buf(csub)
    local function hover_marks()
      local n = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "FibrousButtonHover" then
          n = n + 1
        end
      end
      return n
    end

    handle.focus()
    -- root layout: top=line1, [container: head=line2, [go]=line3, dead=4,5]
    -- control: the real button row DOES hover
    vim.api.nvim_win_set_cursor(handle.winid, { 3, 2 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.is_true(hover_marks() > 0)

    -- the bug: a dead row (root line 5) must NOT hover the last content line
    vim.api.nvim_win_set_cursor(handle.winid, { 5, 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.equal(0, hover_marks())

    -- ...nor activate it
    press("<CR>")
    assert.equal(0, pressed)

    handle.unmount()
  end)

  it("hover tracks the container's LIVE scroll (no offset, no scroll) when the float scrolled since the last sync", function()
    -- follow-mode (and any code) scrolls a container float via a deferred
    -- set_cursor AFTER sync captured the mirror base — so base goes stale. The
    -- parent-driven hover must read the float's live topline, or it lands on a
    -- line offset by the scroll amount AND, being off-screen, its set_cursor
    -- scrolls the float to reveal it.
    local function App()
      local kids = {}
      for i = 1, 8 do
        kids[i] = { comp = ui.label, props = { text = "line" .. i } }
      end
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "top" } },
          { comp = ui.container, props = { height = 3 }, children = kids },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 6 })
    local csub = subwin_of(handle.winid)

    handle.focus()
    -- scroll the float to the bottom, like follow-mode, WITHOUT a parent sync
    vim.api.nvim_win_set_cursor(csub, { 8, 0 })
    vim.api.nvim_win_call(csub, function()
      vim.cmd("normal! zb")
    end)
    local topline = vim.fn.getwininfo(csub)[1].topline
    assert.is_true(topline > 1) -- it really did scroll off the top

    -- hover over the float's TOP visible row (root line 2 = the container's
    -- content top): must map to the live topline, and must not move the scroll
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })

    assert.equal(topline, vim.api.nvim_win_get_cursor(csub)[1]) -- landed on the live line
    assert.equal(topline, vim.fn.getwininfo(csub)[1].topline) -- and didn't scroll the float

    handle.unmount()
  end)

  it("hovering an unfocused container never scrolls it, whatever the global scrolloff", function()
    -- The parent-driven hover nudges the (unfocused) container's cursor to
    -- follow the pointer. With the user's global 'scrolloff' set, landing that
    -- cursor on a top/bottom visible line would drag the view to keep the
    -- margin — scrolling the transcript out from under the reader. The float
    -- pins its own scrolloff/sidescrolloff to 0 so a hover can never move it.
    local function App()
      local kids = {}
      for i = 1, 8 do
        kids[i] = { comp = ui.label, props = { text = "line" .. i } }
      end
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "top" } },
          { comp = ui.container, props = { height = 3 }, children = kids },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 6 })
    local csub = subwin_of(handle.winid)

    handle.focus()
    -- scroll a middle slice into view (room to scroll either way)
    vim.api.nvim_win_call(csub, function()
      vim.fn.winrestview({ topline = 4, lnum = 4, col = 0 })
    end)
    handle.relayout()
    local topline = vim.fn.getwininfo(csub)[1].topline
    assert.is_true(topline > 1)

    -- with a nonzero global scrolloff, an unpinned window scrolls to keep the
    -- margin above the cursor the hover parks on the top visible line
    local saved = vim.o.scrolloff
    vim.o.scrolloff = 5
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    local after = vim.fn.getwininfo(csub)[1].topline
    vim.o.scrolloff = saved

    assert.equal(topline, after)
    handle.unmount()
  end)

  it("on_create hands the app the container's buffer and float once, at creation", function()
    local created = {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = {
              on_create = function(bufnr, winid)
                created[#created + 1] = { bufnr = bufnr, winid = winid }
              end,
            },
            children = { { comp = ui.label, props = { text = "x" } } },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 2 })

    -- once, with the container's own buffer and its float — the app hook for
    -- buffer-local keymaps and window work (follow-scroll, focus)
    local sub = subwin_of(handle.winid)
    assert.same({ { bufnr = vim.api.nvim_win_get_buf(sub), winid = sub } }, created)
    handle.set_props({ tick = 1 })
    assert.equal(1, #created)

    handle.unmount()
  end)

  it("containers nest: a container inside a container gets its own buffer and float", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.label, props = { text = "outer" } },
              {
                comp = ui.container,
                props = {},
                children = {
                  { comp = ui.label, props = { text = "deep" } },
                },
              },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })

    local mid = subwin_of(handle.winid)
    local deep = subwin_of(mid)
    assert.is_not_nil(deep)
    assert.same({ "deep" }, trimmed(vim.api.nvim_win_get_buf(deep)))
    -- and the mid buffer mirrors it, so all three layers read honestly
    assert.same({ "outer", "deep" }, trimmed(vim.api.nvim_win_get_buf(mid)))

    handle.unmount()
  end)

  it("removing a container restores the boundary and deletes its buffer", function()
    local function App(_, props)
      local children = { { comp = ui.label, props = { text = "head" } } }
      if props.show ~= false then
        children[2] = {
          comp = ui.container,
          props = {},
          children = { { comp = ui.label, props = { text = "gone" } } },
        }
      else
        children[2] = { comp = ui.label, props = { text = "plain" } }
      end
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })
    local sub = subwin_of(handle.winid)
    local cbuf = vim.api.nvim_win_get_buf(sub)

    handle.set_props({ show = false })
    assert.is_false(vim.api.nvim_win_is_valid(sub))
    assert.is_false(vim.api.nvim_buf_is_valid(cbuf))
    assert.same({ "head", "plain", "" }, trimmed(handle.bufnr))

    handle.unmount()
  end)

  it("a repaint under the cursor keeps the cursor in place (fold-toggle pattern)", function()
    local function App(_, props)
      local children = {
        { comp = ui.label, props = { text = props.open and "[-] tool" or "[+] tool" } },
      }
      if props.open then
        children[2] = { comp = ui.label, props = { text = "meta 1" } }
        children[3] = { comp = ui.label, props = { text = "meta 2" } }
      end
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.container, props = { height = 4 }, children = children },
        },
      }
    end
    local handle = mount.floating(App, { open = false }, { width = 10, height = 4 })
    local csub = subwin_of(handle.winid)

    -- cursor on the header row, inside the container float — the toggle
    -- rewrites that row (marker flips) and appends the metadata below it
    vim.api.nvim_set_current_win(csub)
    vim.api.nvim_win_set_cursor(csub, { 1, 0 })
    handle.set_props({ open = true })

    assert.same({ "[-] tool", "meta 1", "meta 2" }, trimmed(vim.api.nvim_win_get_buf(csub)))
    -- nvim parks a cursor caught inside a replaced range at the end of the
    -- new text; a flush is a repaint, not an edit — the cursor must not move
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(csub))

    handle.unmount()
  end)

  it("unmount tears everything down, innermost first", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = {},
            children = {
              { comp = ui.text_input, props = { value = "", height = 1 } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })
    local csub = subwin_of(handle.winid)
    local isub = subwin_of(csub)
    local cbuf = vim.api.nvim_win_get_buf(csub)
    local ibuf = vim.api.nvim_win_get_buf(isub)

    handle.unmount()
    for _, win in ipairs({ csub, isub }) do
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end
    for _, buf in ipairs({ cbuf, ibuf }) do
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end
  end)
end)
