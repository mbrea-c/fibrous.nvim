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
