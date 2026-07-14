-- Parent-driven hover must not write the container float's REAL cursor
-- (requests.md: "hjkl navigation in weave causes full redraws, even if no
-- scroll, no streaming, no hover changes … Transcript streaming also causes
-- full redraws").
--
-- hover_at used to nudge the container's window cursor to the translated cell
-- so the child's interact layer could evaluate hover there. But a cursor write
-- into a float invalidates it, and the compositor repaints the WHOLE float —
-- once per root keystroke while moving over the mirror, and once per flush
-- while streaming with the cursor parked on it (each root flush ends in
-- interaction.update() → hover_at). The pointer must instead be DRIVEN into
-- the child layer as data, leaving the float's cursor to the app (follow-to-
-- bottom owns an unfocused container's cursor).

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- (The streaming half of the same requests.md item — full redraws per streamed
-- append with the cursor parked over the mirror — is pinned by
-- mirror_diff_spec.lua and the termdraw guards.)

local NS = vim.api.nvim_create_namespace("fibrous_inline_hover")

-- First float anchored to `winid`.
local function subwin_of(winid)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "win" and cfg.win == winid then
      return win
    end
  end
end

local function move_root_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

-- Count nvim_win_set_cursor calls targeting `winid` while `fn` runs.
local function count_cursor_writes(winid, fn)
  local n = 0
  local orig = vim.api.nvim_win_set_cursor
  vim.api.nvim_win_set_cursor = function(win, ...)
    if win == winid then
      n = n + 1
    end
    return orig(win, ...)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_win_set_cursor = orig
  assert(ok, err)
  return n
end

describe("inline hover drive (no cursor writes into unfocused floats)", function()
  local tick = 0
  local function App()
    return {
      comp = ui.col,
      props = {},
      children = {
        -- a bystander whose text ticks — stands in for weave's water animation
        { comp = ui.label, props = { text = "tick " .. tick } },
        {
          comp = ui.container,
          props = {},
          children = {
            { comp = ui.label, props = { text = "plain one" } },
            { comp = ui.button, props = { label = "hover me", style = { _hover = { hl = "Search" } } } },
            { comp = ui.label, props = { text = "plain two" } },
          },
        },
      },
    }
  end

  it("moving the root cursor over the mirror never writes the float's cursor", function()
    tick = 0
    local handle = mount.floating(App, {}, { width = 24, height = 10 })
    vim.api.nvim_set_current_win(handle.winid)
    local float = assert(subwin_of(handle.winid), "container float not found")
    move_root_cursor(handle, 2, 1) -- row 2 = container's first content row

    local writes = count_cursor_writes(float, function()
      for row = 3, 4 do -- j, j over the mirror (rows 3, 4 = button, plain two)
        move_root_cursor(handle, row, 1)
      end
    end)

    assert.equal(0, writes, "hjkl over the mirror wrote the float cursor " .. writes .. " times (a full-float redraw each)")
    handle.unmount()
  end)

  it("stationary flushes (streaming) never write the float's cursor", function()
    tick = 0
    local handle = mount.floating(App, {}, { width = 24, height = 10 })
    vim.api.nvim_set_current_win(handle.winid)
    local float = assert(subwin_of(handle.winid), "container float not found")
    move_root_cursor(handle, 3, 1) -- parked over the button

    local writes = count_cursor_writes(float, function()
      for i = 1, 5 do -- flushes with the pointer stationary — the streaming posture
        tick = i
        handle.set_props({})
      end
    end)

    assert.equal(0, writes, "stationary flushes wrote the float cursor " .. writes .. " times (a full-float redraw each)")
    handle.unmount()
  end)

  it("hover still paints on the container when driven without a cursor write", function()
    tick = 0
    local handle = mount.floating(App, {}, { width = 24, height = 10 })
    vim.api.nvim_set_current_win(handle.winid)
    local float = assert(subwin_of(handle.winid), "container float not found")
    local fbuf = vim.api.nvim_win_get_buf(float)

    move_root_cursor(handle, 3, 1) -- over the button, inside the container
    local marks = vim.api.nvim_buf_get_extmarks(fbuf, NS, 0, -1, {})
    assert.is_true(#marks > 0, "driven hover no longer paints the container's overlay")

    move_root_cursor(handle, 1, 1) -- pointer leaves the container
    marks = vim.api.nvim_buf_get_extmarks(fbuf, NS, 0, -1, {})
    assert.equal(0, #marks, "hover overlay not cleared when the pointer left the container")
    handle.unmount()
  end)
end)
