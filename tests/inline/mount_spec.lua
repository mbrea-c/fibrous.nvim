-- The inline mount targets (tracker "NEW UI HOST" task 3): both put the host
-- buffer in a root float (tracker decision: always a root float, so host-window
-- resizes can never clobber widgets between relayouts).
--   floating — an editor-relative float IS the app window.
--   split    — a native split pane provides geometry; a relative="win" float
--              covers it edge to edge, resynced on resize, torn down when the
--              pane closes.
-- `mode = "scroll"` lays out at nil height (buffer grows, window is a
-- viewport); the default "fixed" paints the exact window height (app mode).

local mount = require("fibrous.inline.mount")

local col = { __host = "col" }
local text = { __host = "text" }

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function Hello()
  return { comp = text, props = { text = "hello" } }
end

-- Autocmds in any fibrous-inline mount group, for wiring assertions.
local function inline_autocmds(event)
  local out = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
    if (au.group_name or ""):find("FibrousInline", 1, true) then
      out[#out + 1] = au
    end
  end
  return out
end

describe("inline.mount", function()
  it("floating: opens an editor-relative float showing the painted tree", function()
    local handle = mount.floating(Hello, {}, { width = 10, height = 3 })

    assert.is_true(vim.api.nvim_win_is_valid(handle.winid))
    local cfg = vim.api.nvim_win_get_config(handle.winid)
    assert.equal("editor", cfg.relative)
    assert.equal(10, cfg.width)
    assert.equal(3, cfg.height)
    assert.equal(handle.bufnr, vim.api.nvim_win_get_buf(handle.winid))
    assert.is_false(vim.wo[handle.winid].wrap)
    -- app mode (default): the canvas is the full fixed height
    assert.same({ "hello     ", "          ", "          " }, lines_of(handle.bufnr))

    handle.unmount()
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
  end)

  it("floating scroll mode: the buffer grows past the window height", function()
    local function App()
      local children = {}
      for i = 1, 6 do
        children[i] = { comp = text, props = { text = "line " .. i } }
      end
      return { comp = col, props = {}, children = children }
    end

    local handle = mount.floating(App, {}, { width = 8, height = 3, mode = "scroll" })

    assert.equal(6, #lines_of(handle.bufnr))
    assert.equal(3, vim.api.nvim_win_get_config(handle.winid).height)

    handle.unmount()
  end)

  it("scroll mode: topline scrolls free, leftcol snaps back (x locked by default)", function()
    local function App()
      local children = {}
      for i = 1, 6 do
        children[i] = { comp = text, props = { text = "line " .. i } }
      end
      return { comp = col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3, mode = "scroll" })

    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = 2, leftcol = 3 })
    end)
    -- deterministic re-pin through the same restore the WinScrolled path
    -- defers (the subwin specs drive scroll resyncs the same way)
    handle.relayout()

    local v = vim.api.nvim_win_call(handle.winid, vim.fn.winsaveview)
    assert.equal(0, v.leftcol) -- sideways drag undone: no content ever lives there
    assert.equal(2, v.topline) -- the vertical scroll is the mode's whole point

    handle.unmount()
  end)

  it("scroll_x = true frees the horizontal axis explicitly", function()
    local function App()
      return { comp = text, props = { text = "wide" } }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3, mode = "scroll", scroll_x = true })

    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ leftcol = 2 })
    end)
    vim.wait(100)
    local v = vim.api.nvim_win_call(handle.winid, vim.fn.winsaveview)
    assert.equal(2, v.leftcol)

    handle.unmount()
  end)

  it("fixed mode still pins both axes", function()
    local handle = mount.floating(Hello, {}, { width = 10, height = 3 })

    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = 2, leftcol = 2 })
    end)
    handle.relayout()

    local v = vim.api.nvim_win_call(handle.winid, vim.fn.winsaveview)
    assert.equal(1, v.topline)
    assert.equal(0, v.leftcol)

    handle.unmount()
  end)

  it("split: opens a pane fully covered by the root float", function()
    local function App()
      return { comp = text, props = { text = "sidebar" } }
    end

    local handle = mount.split(App, {}, { split = { size = 20 }, mode = "scroll" })

    assert.is_true(vim.api.nvim_win_is_valid(handle.host_winid))
    local cfg = vim.api.nvim_win_get_config(handle.winid)
    assert.equal("win", cfg.relative)
    assert.equal(handle.host_winid, cfg.win)
    assert.equal(20, cfg.width)
    assert.equal(vim.api.nvim_win_get_height(handle.host_winid), cfg.height)
    assert.same({ "sidebar" .. string.rep(" ", 13) }, lines_of(handle.bufnr))

    handle.unmount()
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    assert.is_false(vim.api.nvim_win_is_valid(handle.host_winid))
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
  end)

  it("split: relayout follows a pane resize (float resized, text rewrapped)", function()
    local function App()
      return { comp = text, props = { text = "the quick", wrap = true } }
    end
    local handle = mount.split(App, {}, { split = { size = 12 }, mode = "scroll" })
    assert.same({ "the quick   " }, lines_of(handle.bufnr))

    vim.api.nvim_win_set_width(handle.host_winid, 5)
    handle.relayout()

    assert.equal(5, vim.api.nvim_win_get_config(handle.winid).width)
    assert.same({ "the  ", "quick" }, lines_of(handle.bufnr))

    handle.unmount()
  end)

  it("split: subwindow floats anchor to the inert pane, never to a float's read position", function()
    -- The anchoring contract for pane-backed mounts. relative="win" to the
    -- PANE: it is inert (no cursor, no buffer edits), so the whole-float
    -- redraw pathology can't trigger, and nvim moves the floats with the
    -- pane atomically on layout changes. And the offset must come from the
    -- manager's own applied geometry, never nvim_win_get_position on a
    -- float: between a set_config and the next redraw a float reports a
    -- stale composite (anchor + old position), which planted subwindows at
    -- roughly DOUBLE the pane offset for a frame per WinResized-triggered
    -- sync: the transcript's teleport-right-and-back while typing with the
    -- pum open (its info float resizes per keystroke) and while resizing.
    local ui = require("fibrous.inline.components")
    local function App(_, props)
      local children = {}
      for i = 1, (props.headers or 1) do
        children[#children + 1] = { comp = text, props = { text = "header " .. i } }
      end
      children[#children + 1] = {
        comp = ui.container,
        props = { height = 3 },
        children = { { comp = text, props = { text = "inside" } } },
      }
      return { comp = col, props = {}, children = children }
    end

    local handle = mount.split(App, { headers = 1 }, { split = { size = 20 }, mode = "scroll" })
    local sub
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[w].fibrous_anchor == handle.winid then
        sub = w
      end
    end
    assert.is_not_nil(sub)

    local cfg = vim.api.nvim_win_get_config(sub)
    assert.equal("win", cfg.relative)
    assert.equal(handle.host_winid, cfg.win) -- the pane, NOT the root float
    assert.equal(1, cfg.row) -- pane-relative: one header above
    assert.equal(0, cfg.col)

    -- Open the lie window: re-apply the root float's config exactly like
    -- mount's sync() does, then reposition through a layout change. The
    -- subwindow's offset must stay pane-relative: on the win_get_position
    -- diet it came out pane-absolute (the doubled offset).
    local root_cfg = vim.api.nvim_win_get_config(handle.winid)
    vim.api.nvim_win_set_config(handle.winid, {
      relative = "win",
      win = root_cfg.win,
      row = root_cfg.row,
      col = root_cfg.col,
      width = root_cfg.width,
      height = root_cfg.height,
    })
    handle.set_props({ headers = 2 })

    -- unkeyed children re-indexed: the container fiber (and its float) was
    -- recreated: find it again; creation goes through the same reposition
    sub = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[w].fibrous_anchor == handle.winid then
        sub = w
      end
    end
    assert.is_not_nil(sub)
    cfg = vim.api.nvim_win_get_config(sub)
    assert.equal("win", cfg.relative)
    assert.equal(handle.host_winid, cfg.win)
    assert.equal(2, cfg.row) -- moved one row down, still pane-relative
    assert.equal(0, cfg.col)

    handle.unmount()
  end)

  it("floating: subwindow floats stay editor-anchored (no pane exists)", function()
    local ui = require("fibrous.inline.components")
    local function App()
      return {
        comp = col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = { height = 3 },
            children = { { comp = text, props = { text = "inside" } } },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 20, height = 6 })
    local sub
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[w].fibrous_anchor == handle.winid then
        sub = w
      end
    end
    assert.is_not_nil(sub)
    assert.equal("editor", vim.api.nvim_win_get_config(sub).relative)
    handle.unmount()
  end)

  it("resize-sync autocmds are wired while mounted and cleared on unmount", function()
    local handle = mount.split(Hello, {}, {})

    assert.is_true(#inline_autocmds("WinResized") > 0)

    handle.unmount()
    assert.equal(0, #inline_autocmds("WinResized"))
  end)

  it("split: closing the pane unmounts the whole app", function()
    local handle = mount.split(Hello, {}, {})

    vim.api.nvim_win_close(handle.host_winid, true)
    -- teardown is deferred (windows can't close inside WinClosed); pump it
    vim.wait(500, function()
      return not vim.api.nvim_buf_is_valid(handle.bufnr)
    end, 10)

    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    assert.equal(0, #inline_autocmds("WinResized"))
  end)

  it("split: :q on the root float tears down the app AND its pane", function()
    local wins_before = #vim.api.nvim_list_wins()
    local handle = mount.split(Hello, {}, {})

    vim.api.nvim_win_close(handle.winid, true) -- what :q on the float does
    vim.wait(500, function()
      return not vim.api.nvim_buf_is_valid(handle.bufnr)
    end, 10)

    assert.is_false(vim.api.nvim_win_is_valid(handle.host_winid))
    assert.equal(wins_before, #vim.api.nvim_list_wins())
  end)

  it("on_unmount fires exactly once, however the app dies", function()
    -- Embedders (perijove notebook sessions) must learn about teardown they
    -- did not initiate (:q on the pane or the float), or their session state
    -- dangles on a dead mount.
    local counts = { 0, 0, 0 }

    local h1 = mount.split(Hello, {}, {
      on_unmount = function()
        counts[1] = counts[1] + 1
      end,
    })
    h1.unmount()
    h1.unmount() -- teardown is idempotent; the callback must be too
    assert.equal(1, counts[1])

    local h2 = mount.split(Hello, {}, {
      on_unmount = function()
        counts[2] = counts[2] + 1
      end,
    })
    vim.api.nvim_win_close(h2.host_winid, true)
    vim.wait(500, function()
      return counts[2] > 0
    end, 10)
    assert.equal(1, counts[2])

    local h3 = mount.floating(Hello, {}, {
      width = 10,
      height = 3,
      on_unmount = function()
        counts[3] = counts[3] + 1
      end,
    })
    vim.api.nvim_win_close(h3.winid, true)
    vim.wait(500, function()
      return counts[3] > 0
    end, 10)
    assert.equal(1, counts[3])
  end)

  it("split: entering the pane behind the float forwards focus to the app", function()
    local handle = mount.split(Hello, {}, {})

    -- <C-w>-navigation only sees layout windows, so it lands on the blank
    -- scratch pane the float covers — the mount forwards focus to the float
    vim.api.nvim_set_current_win(handle.host_winid)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())

    handle.unmount()
  end)

  it("fixed mode pins the root view: a scroll snaps back; scroll mode scrolls", function()
    local function view_of(winid)
      local v
      vim.api.nvim_win_call(winid, function()
        v = vim.fn.winsaveview()
      end)
      return v
    end

    -- WinScrolled is a redraw-time check that never fires in headless -l:
    -- scroll, then deliver the event by hand (as the redraw would)
    local function scroll(winid)
      vim.api.nvim_win_call(winid, function()
        vim.fn.winrestview({ topline = 2, lnum = 2, col = 0 })
      end)
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(winid) })
    end

    -- the restore is deferred to the main loop (an inline restore would
    -- desync nvim's per-window scroll checkpoint and stop the event firing
    -- for repeat scrolls to the same topline): pump it
    local fixed = mount.floating(Hello, {}, { width = 10, height = 3 })
    scroll(fixed.winid)
    vim.wait(200, function()
      return view_of(fixed.winid).topline == 1
    end, 10)
    assert.equal(1, view_of(fixed.winid).topline)

    -- scroll mode: the window is a real viewport, scrolling must survive
    local function Tall()
      local children = {}
      for i = 1, 6 do
        children[i] = { comp = text, props = { text = "line " .. i } }
      end
      return { comp = col, props = {}, children = children }
    end
    local scroller = mount.floating(Tall, {}, { width = 8, height = 3, mode = "scroll" })
    scroll(scroller.winid)
    vim.wait(50) -- long enough for a (wrongly) deferred restore to land
    assert.equal(2, view_of(scroller.winid).topline)

    fixed.unmount()
    scroller.unmount()
  end)

  it("fixed mode: a relayout (resize) re-pins the root view even with no WinScrolled", function()
    -- Shrinking the OS window makes nvim scroll the root float to keep the
    -- cursor visible (its 'scrolloff' margin), and that resize-time scroll does
    -- NOT deliver a WinScrolled the pin handler can catch — so the panel stayed
    -- scrolled until a manual scroll snapped it back. A relayout (what
    -- VimResized/WinResized trigger) must re-pin the view itself.
    local function view_of(winid)
      local v
      vim.api.nvim_win_call(winid, function()
        v = vim.fn.winsaveview()
      end)
      return v
    end

    local fixed = mount.floating(Hello, {}, { width = 10, height = 3 })
    -- the root has no scroll margin of its own to fight a resize with
    assert.equal(0, vim.wo[fixed.winid].scrolloff)
    assert.equal(0, vim.wo[fixed.winid].sidescrolloff)

    -- scroll WITHOUT delivering WinScrolled (the resize path the pin missed)
    vim.api.nvim_win_call(fixed.winid, function()
      vim.fn.winrestview({ topline = 2, lnum = 2, col = 0 })
    end)
    fixed.relayout() -- what a resize event triggers
    assert.equal(1, view_of(fixed.winid).topline)

    fixed.unmount()
  end)

  it("window: winid = 0 resolves to the current window at mount time", function()
    local origin = vim.api.nvim_get_current_win()
    local handle = mount.window(Hello, {}, { winid = 0, mode = "scroll" })

    -- the handle and the float anchor carry the CONCRETE id, not 0
    assert.equal(origin, handle.host_winid)
    assert.equal(origin, vim.api.nvim_win_get_config(handle.winid).win)

    -- focusing the float makes IT the current window; a later geometry sync
    -- must still anchor to the origin — a raw 0 would re-resolve to the float
    -- itself ("floating window cannot be relative to itself")
    handle.focus()
    handle.relayout()
    assert.equal(origin, vim.api.nvim_win_get_config(handle.winid).win)

    handle.unmount()
  end)

  it("window: teardown leaves the mounted-on window alone (the embedder owns it)", function()
    -- M.split closes its pane on teardown because it OPENED that pane;
    -- M.window mounts over a window somebody else created (perijove: the
    -- window the .ipynb buffer is open in) — unmounting the app, however it
    -- happens, must hand that window back, not close it. Whoever mounted
    -- decides window policy through on_unmount.
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_win_get_buf(target)

    local handle = mount.window(Hello, {}, { winid = target, mode = "scroll" })
    handle.unmount()
    assert.is_true(vim.api.nvim_win_is_valid(target))
    assert.equal(target_buf, vim.api.nvim_win_get_buf(target))

    -- :q on the root float: app dies, window survives
    local unmounted = false
    handle = mount.window(Hello, {}, {
      winid = target,
      mode = "scroll",
      on_unmount = function()
        unmounted = true
      end,
    })
    vim.api.nvim_win_close(handle.winid, true)
    vim.wait(500, function()
      return unmounted
    end, 10)
    assert.is_true(vim.api.nvim_win_is_valid(target))
    vim.cmd("tabclose")
  end)

  it("buffer: renders into the window itself, with no covering float", function()
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()

    local handle = mount.buffer(Hello, {}, { winid = target })

    -- the defining property: the handle's window IS the target, it is an
    -- ordinary window, and it shows the host buffer directly
    assert.equal(target, handle.winid)
    assert.equal(target, handle.host_winid)
    assert.equal("", vim.api.nvim_win_get_config(target).relative)
    assert.equal(handle.bufnr, vim.api.nvim_win_get_buf(target))
    -- style="minimal" is unavailable here and reproduced by hand; wrap is the
    -- one that would break rect math outright
    assert.is_false(vim.wo[target].wrap)
    assert.is_false(vim.wo[target].number)
    assert.equal("no", vim.wo[target].signcolumn)
    assert.equal("hello", lines_of(handle.bufnr)[1]:sub(1, 5))

    handle.unmount()
    vim.cmd("tabclose")
  end)

  -- A buffer mount's host window paints on Normal, but its sub-buffer floats
  -- (containers, inputs, popups) default to NormalFloat — so the mount remaps
  -- them onto Normal to read as one background. A floating mount leaves them on
  -- NormalFloat, reading as overlays.
  local function anchored_floats(anchor)
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == anchor then
        out[#out + 1] = win
      end
    end
    return out
  end

  local function ContainerApp()
    return {
      comp = col,
      props = {},
      children = {
        { comp = text, props = { text = "head" } },
        {
          comp = { __host = "container" },
          props = {},
          children = { { comp = text, props = { text = "inner" } } },
        },
      },
    }
  end

  it("buffer: sub-buffer floats map NormalFloat onto the host's Normal", function()
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()

    local handle = mount.buffer(ContainerApp, {}, { winid = target })

    local floats = anchored_floats(target)
    assert.is_true(#floats > 0)
    for _, win in ipairs(floats) do
      -- appended to (not replacing) whatever style="minimal" set, so the
      -- EndOfBuffer hiding survives alongside the Normal remap
      assert.truthy(vim.wo[win].winhighlight:find("NormalFloat:Normal", 1, true))
    end

    handle.unmount()
    vim.cmd("tabclose")
  end)

  it("floating: sub-buffer floats keep NormalFloat (overlay look, no remap)", function()
    local handle = mount.floating(ContainerApp, {}, { width = 12, height = 6 })

    local floats = anchored_floats(handle.winid)
    assert.is_true(#floats > 0)
    for _, win in ipairs(floats) do
      assert.is_nil(vim.wo[win].winhighlight:find("NormalFloat:", 1, true))
    end

    handle.unmount()
  end)

  it("buffer: teardown puts the embedder's buffer back and keeps the window", function()
    -- The failure this pins: root:unmount() deletes the host buffer, and
    -- deleting a buffer that a REAL window is displaying takes the window
    -- down with it ("Invalid window id"). A float mount never noticed,
    -- because teardown closes its float first anyway.
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_win_get_buf(target)

    local handle = mount.buffer(Hello, {}, { winid = target })
    assert.equal(target_buf, handle.prev_bufnr)
    local host_buf = handle.bufnr

    handle.unmount()

    assert.is_true(vim.api.nvim_win_is_valid(target))
    assert.equal(target_buf, vim.api.nvim_win_get_buf(target))
    assert.is_false(vim.api.nvim_buf_is_valid(host_buf))
    -- window options handed back too, not left on the app's minimal set
    assert.is_true(vim.wo[target].wrap)

    vim.cmd("tabclose")
  end)

  it("buffer: closing the window unmounts the app", function()
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()

    local unmounted = false
    local handle = mount.buffer(Hello, {}, {
      winid = target,
      on_unmount = function()
        unmounted = true
      end,
    })
    vim.api.nvim_win_close(target, true)
    vim.wait(500, function()
      return unmounted
    end, 10)

    assert.is_true(unmounted)
    assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    vim.cmd("tabclose")
  end)

  it("buffer: a resize relayouts the canvas to the new window size", function()
    -- The objection this mount type was measured against: rendering straight
    -- into a host window was said to let a resize clobber widgets before the
    -- relayout. There is no float to resync here, so the canvas simply
    -- re-lays-out at the window's new size.
    vim.cmd("tabnew")
    vim.cmd("topleft vsplit")
    local target = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(target, 20)

    local handle = mount.buffer(Hello, {}, { winid = target })
    assert.equal(20, #lines_of(handle.bufnr)[1])

    vim.api.nvim_win_set_width(target, 34)
    handle.relayout()
    assert.equal(34, #lines_of(handle.bufnr)[1])

    handle.unmount()
    vim.cmd("tabclose")
  end)

  it("buffer: survives its previous buffer being wiped while mounted", function()
    -- release_root puts prev_bufnr back; if the embedder wiped it meanwhile,
    -- the window must still end up on SOMETHING rather than following the
    -- host buffer into deletion.
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(target, scratch)

    local handle = mount.buffer(Hello, {}, { winid = target })
    vim.api.nvim_buf_delete(scratch, { force = true })
    handle.unmount()

    assert.is_true(vim.api.nvim_win_is_valid(target))
    assert.is_true(vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(target)))
    vim.cmd("tabclose")
  end)

  it("buffer: two windows on the host buffer render a refusal, not a broken layout", function()
    -- One buffer, two windows, one canvas. There is no way to show the app in
    -- both: subwindow floats anchor to a single window, and the two viewports
    -- would fight over the same lines. Nothing can be rendered per-window
    -- either, because the CONTENT is shared. So the app refuses out loud
    -- rather than drawing a half-working UI in both.
    vim.cmd("tabnew")
    local target = vim.api.nvim_get_current_win()
    local handle = mount.buffer(Hello, {}, { winid = target })
    assert.equal("hello", lines_of(handle.bufnr)[1]:sub(1, 5))

    vim.cmd("split") -- a second window onto the SAME host buffer
    vim.wait(200, function()
      return (lines_of(handle.bufnr)[1] or ""):find("two windows") ~= nil
    end, 10)

    local text = table.concat(lines_of(handle.bufnr), "\n")
    assert.truthy(text:find("cannot render fibrous buffer in two windows at once", 1, true))
    assert.is_nil(text:find("hello", 1, true))

    -- and back: closing the extra window restores the real UI
    vim.cmd("close")
    vim.wait(200, function()
      return (table.concat(lines_of(handle.bufnr), "\n")):find("hello", 1, true) ~= nil
    end, 10)
    local restored = table.concat(lines_of(handle.bufnr), "\n")
    assert.truthy(restored:find("hello", 1, true))
    assert.is_nil(restored:find("cannot render", 1, true))

    handle.unmount()
    vim.cmd("tabclose")
  end)

  it("buffer: the refusal is centered, and stays readable in a narrow pane", function()
    -- 34 columns: NARROWER than the 51-column message, which is the case a
    -- sidebar actually hits. A label would be truncated mid-sentence and
    -- left-aligned (align_self cannot centre something wider than its
    -- container), so the message wraps.
    for _, width in ipairs({ 34, 70 }) do
      vim.cmd("tabnew")
      local target = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(target, width)
      local handle = mount.buffer(Hello, {}, { winid = target })
      vim.cmd("split")
      vim.wait(300, function()
        return table.concat(lines_of(handle.bufnr), "\n"):find("cannot render", 1, true) ~= nil
      end, 10)

      local lines = lines_of(handle.bufnr)
      local first, last
      for i, l in ipairs(lines) do
        if l:match("%S") then
          first = first or i
          last = i
        end
      end
      assert.truthy(first)

      -- nothing is lost to truncation: every word survives somewhere
      local joined = table.concat(lines, " "):gsub("%s+", " ")
      for word in ("cannot render fibrous buffer in two windows at once"):gmatch("%S+") do
        assert.truthy(joined:find(word, 1, true), ("width %d lost %q"):format(width, word))
      end

      -- each rendered line is centered horizontally
      for i = first, last do
        local body = lines[i]
        if body:match("%S") then
          local lead = #body:match("^ *")
          local trail = #body:match(" *$")
          assert.is_true(math.abs(lead - trail) <= 1, ("width %d row %d not centered"):format(width, i))
        end
      end
      -- and the block is centered vertically
      assert.is_true(math.abs((first - 1) - (#lines - last)) <= 1)

      handle.unmount()
      vim.cmd("tabclose")
    end
  end)

  it("split render=buffer: the pane draws itself, and teardown closes it", function()
    vim.cmd("tabnew")
    local before = #vim.api.nvim_tabpage_list_wins(0)

    local handle = mount.split(Hello, {}, { render = "buffer", split = { size = 24 } })

    -- one window added, not two: a float mount would contribute the pane AND
    -- its covering float
    assert.equal(before + 1, #vim.api.nvim_tabpage_list_wins(0))
    assert.equal("", vim.api.nvim_win_get_config(handle.winid).relative)
    assert.equal(handle.bufnr, vim.api.nvim_win_get_buf(handle.winid))
    assert.equal(24, #lines_of(handle.bufnr)[1])

    -- M.split OPENED this pane, so unlike a bare buffer mount it closes it
    handle.unmount()
    assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    vim.cmd("tabclose")
  end)

  it("set_props re-renders through the mounted root", function()
    local function App(_, props)
      return { comp = text, props = { text = props.msg } }
    end
    local handle = mount.floating(App, { msg = "one" }, { width = 5, height = 1 })
    assert.same({ "one  " }, lines_of(handle.bufnr))

    handle.set_props({ msg = "two" })

    assert.same({ "two  " }, lines_of(handle.bufnr))
    handle.unmount()
  end)
end)

-- Stacking policy + modal chrome. Pane-anchored mounts (window/split) are
-- page furniture: their whole float stack sits BELOW nvim's default float
-- zindex (50), so genuine floats — float-mounted fibrous apps, any other
-- plugin's popups — always render above them. Float mounts root at the
-- default 50, and every subwindow level stacks root+1.
describe("inline.mount stacking and modal chrome", function()
  local ui = require("fibrous.inline.components")

  -- An app whose single child is a container; on_create captures its float.
  local function container_app(captured)
    return function()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = {
              grow = 1,
              on_create = function(bufnr, winid)
                captured.bufnr, captured.winid = bufnr, winid
              end,
            },
            children = { { comp = ui.label, props = { text = "inside" } } },
          },
        },
      }
    end
  end

  it("pane-anchored mounts stack below the float default; float mounts at it", function()
    local origin = vim.api.nvim_get_current_win()
    local paned = {}
    local split_handle = mount.split(container_app(paned), {}, { split = { size = 30 } })
    assert.equal(10, vim.api.nvim_win_get_config(split_handle.winid).zindex)
    assert.equal(11, vim.api.nvim_win_get_config(paned.winid).zindex)

    local floated = {}
    local float_handle = mount.floating(container_app(floated), {}, { width = 20, height = 5 })
    assert.equal(50, vim.api.nvim_win_get_config(float_handle.winid).zindex)
    assert.equal(51, vim.api.nvim_win_get_config(floated.winid).zindex)

    float_handle.unmount()
    split_handle.unmount()
    vim.api.nvim_set_current_win(origin)
  end)

  it("opts.zindex overrides the root; subwindow levels follow it", function()
    local captured = {}
    local handle = mount.floating(container_app(captured), {}, { width = 20, height = 5, zindex = 200 })
    assert.equal(200, vim.api.nvim_win_get_config(handle.winid).zindex)
    assert.equal(201, vim.api.nvim_win_get_config(captured.winid).zindex)
    handle.unmount()
  end)

  it("backdrop: a dimming float behind the root, torn down with the mount", function()
    local before = #vim.api.nvim_list_wins()
    local handle = mount.floating(Hello, {}, { width = 10, height = 3, backdrop = true })

    -- The backdrop sits one z-level below the root, covering EVERYTHING
    -- behind the app. nvim's compositor can't blend floats through a
    -- winblend float, so lower floats (docked fibrous apps included) are
    -- hidden outright while normal windows dim — obscuring the page
    -- furniture is the intended modal effect (user decision over leaving
    -- it visible-but-undimmed below the backdrop).
    local backdrop
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.zindex == 49 then
        backdrop = { winid = w, cfg = cfg }
      end
    end
    assert.is_not_nil(backdrop)
    -- covers the whole editor, can't take focus
    assert.equal(vim.o.columns, backdrop.cfg.width)
    assert.equal(vim.o.lines, backdrop.cfg.height)
    assert.is_false(backdrop.cfg.focusable)
    assert.truthy(vim.wo[backdrop.winid].winhighlight:find("FibrousBackdrop", 1, true))

    handle.unmount()
    assert.is_false(vim.api.nvim_win_is_valid(backdrop.winid))
    assert.equal(before, #vim.api.nvim_list_wins())
  end)

  it("border: passed through to the root float and kept across relayout", function()
    local handle = mount.floating(Hello, {}, { width = 10, height = 3, border = "rounded" })
    local cfg = vim.api.nvim_win_get_config(handle.winid)
    assert.is_true(type(cfg.border) == "table")

    handle.relayout()
    cfg = vim.api.nvim_win_get_config(handle.winid)
    assert.is_true(type(cfg.border) == "table")
    handle.unmount()
  end)
end)
