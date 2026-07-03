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
