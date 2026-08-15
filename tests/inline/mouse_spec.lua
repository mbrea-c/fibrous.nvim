-- The mouse pointer as a SECOND, focus-independent pointer (interact.lua's
-- mouse lane + the global <MouseMove> router in mousemove.lua). Both pointers'
-- hovers paint at once in separate namespaces — the cursor's above the
-- mouse's (extmark priority 4200 vs 4150) — a structural hover claimed by
-- both releases only when both leave, and mouse activation is separately
-- handleable from <CR> (role `on_click`, `on_press(x, source)`).
--
-- Headless nvim has no pointer, so the router's getmousepos seam is stubbed;
-- everything downstream of it (routing, hit walk, painting, activation) is
-- the real code path.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local mousemove = require("fibrous.inline.mousemove")

local real_getmousepos = mousemove._getmousepos

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Extmarks of one named namespace, as { row, col, end_col, hl, priority }.
local function ns_marks(bufnr, ns_name)
  local ns = vim.api.nvim_get_namespaces()[ns_name]
  if not ns then
    return {}
  end
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    out[#out + 1] = {
      row = m[2],
      col = m[3],
      end_col = m[4].end_col,
      hl = m[4].hl_group,
      priority = m[4].priority,
    }
  end
  return out
end

local function move_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

local function press(handle, key)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- Stub the pointer at buffer position (row 1-based, col 0-based BYTE) of
-- `winid` and deliver one <MouseMove> through the router. Screen cells are
-- derived per position so the router's dedupe never eats a distinct move.
local function point(winid, row, col)
  mousemove._getmousepos = function()
    return {
      winid = winid,
      line = row,
      column = col + 1,
      coladd = 0,
      screenrow = 100 + row,
      screencol = 100 + col,
    }
  end
  mousemove._on_move()
end

-- Run the buffer-local <LeftRelease> mapping the way a real click lands:
-- pointer at the cell (stub), cursor moved there by the press (native
-- mouse=nvi behavior), then the release fires the activate path.
local function click(handle, row, col)
  point(handle.winid, row, col)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
end

describe("inline.mouse", function()
  after_each(function()
    mousemove._getmousepos = real_getmousepos
  end)

  local function two_buttons()
    return {
      comp = ui.col,
      props = {},
      children = {
        { comp = ui.button, props = { label = "OK" } },
        { comp = ui.button, props = { label = "GO" } },
      },
    }
  end

  it("pointer hover paints without moving the cursor; both pointers show at once", function()
    local handle = mount.floating(two_buttons, {}, { width = 10, height = 4 })

    move_cursor(handle, 1, 0) -- cursor on button 1 (row 0)
    point(handle.winid, 2, 0) -- pointer on button 2 (row 1)

    local cursor_marks = ns_marks(handle.bufnr, "fibrous_inline_hover")
    local mouse_marks = ns_marks(handle.bufnr, "fibrous_inline_mouse_hover")
    assert.equal(1, #cursor_marks)
    assert.equal(0, cursor_marks[1].row)
    assert.equal(1, #mouse_marks)
    assert.equal(1, mouse_marks[1].row)
    -- the pointer did NOT drag the cursor along (that's `follow`, not this)
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(handle.winid))

    handle.unmount()
  end)

  it("where both pointers overlap, the cursor's marks sit above (priority)", function()
    local handle = mount.floating(two_buttons, {}, { width = 10, height = 4 })

    move_cursor(handle, 1, 0)
    point(handle.winid, 1, 0) -- same button, same cells

    local cursor_marks = ns_marks(handle.bufnr, "fibrous_inline_hover")
    local mouse_marks = ns_marks(handle.bufnr, "fibrous_inline_mouse_hover")
    assert.equal(1, #cursor_marks)
    assert.equal(1, #mouse_marks)
    assert.equal(cursor_marks[1].row, mouse_marks[1].row)
    assert.is_true(cursor_marks[1].priority > mouse_marks[1].priority)

    handle.unmount()
  end)

  it("the pointer leaving the window clears the mouse lane only", function()
    local handle = mount.floating(two_buttons, {}, { width = 10, height = 4 })

    move_cursor(handle, 1, 0)
    point(handle.winid, 2, 0)
    assert.equal(1, #ns_marks(handle.bufnr, "fibrous_inline_mouse_hover"))

    point(9999, 1, 0) -- some other window entirely
    assert.equal(0, #ns_marks(handle.bufnr, "fibrous_inline_mouse_hover"))
    assert.equal(1, #ns_marks(handle.bufnr, "fibrous_inline_hover"))

    handle.unmount()
  end)

  it("a structural hover claimed by both pointers releases only when both leave", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "title" } },
          -- padding x=3 differs from the button theme's base (x=1), so the
          -- structural hover visibly rewraps the chip
          { comp = ui.button, props = { label = "OK", style = { _hover = { padding = { x = 3 } } } } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 4 })
    local base = lines_of(handle.bufnr)[2]

    move_cursor(handle, 2, 0) -- cursor claims the structural hover
    local hovered = lines_of(handle.bufnr)[2]
    assert.is_true(hovered ~= base)

    point(handle.winid, 2, 0) -- pointer claims it too
    assert.equal(hovered, lines_of(handle.bufnr)[2])

    move_cursor(handle, 1, 0) -- cursor leaves: the POINTER still holds it
    assert.equal(hovered, lines_of(handle.bufnr)[2])

    point(handle.winid, 1, 0) -- pointer leaves too: now it releases
    assert.equal(base, lines_of(handle.bufnr)[2])

    handle.unmount()
  end)

  it("mouse activation takes on_click over on_press; keyboard stays on_press", function()
    local clicks, presses = {}, {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.button,
            props = {
              label = "A",
              on_click = function(x)
                clicks[#clicks + 1] = x
              end,
              on_press = function(x, source)
                presses[#presses + 1] = { x = x, source = source }
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })

    click(handle, 1, 0)
    assert.equal(1, #clicks)
    assert.equal(0, #presses)

    move_cursor(handle, 1, 0)
    press(handle, "<CR>")
    assert.equal(1, #clicks)
    assert.equal(1, #presses)
    assert.equal("key", presses[1].source)

    handle.unmount()
  end)

  it("without on_click, mouse activation falls back to on_press with source \"mouse\"", function()
    local presses = {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.button,
            props = {
              label = "B",
              on_press = function(x, source)
                presses[#presses + 1] = { x = x, source = source }
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })

    click(handle, 1, 0)
    assert.equal(1, #presses)
    assert.equal("mouse", presses[1].source)

    handle.unmount()
  end)

  it("installs the global <MouseMove> mappings while layers exist, removing them after", function()
    assert.equal("", vim.fn.maparg("<MouseMove>", "n"))
    assert.equal("", vim.fn.maparg("<MouseMove>", "i"))

    local handle = mount.floating(two_buttons, {}, { width = 10, height = 4 })
    assert.equal("function", type(vim.fn.maparg("<MouseMove>", "n", false, true).callback))
    -- insert mode too: hover the canvas while typing in a prompt subwindow
    assert.equal("function", type(vim.fn.maparg("<MouseMove>", "i", false, true).callback))

    handle.unmount()
    assert.equal("", vim.fn.maparg("<MouseMove>", "n"))
    assert.equal("", vim.fn.maparg("<MouseMove>", "i"))
  end)

  it("router: routes to the owning layer, clears the ones the pointer left, dedupes cells", function()
    local a = { at = 0, cleared = 0 }
    local b = { at = 0, cleared = 0 }
    local function layer(rec)
      return {
        mouse_at = function()
          rec.at = rec.at + 1
        end,
        mouse_clear = function()
          rec.cleared = rec.cleared + 1
        end,
      }
    end
    mousemove.register(1111, layer(a))
    mousemove.register(2222, layer(b))

    point(1111, 1, 0)
    point(1111, 1, 0) -- same screen cell: coalesced, no second delivery
    assert.equal(1, a.at)

    point(2222, 3, 0) -- pointer crosses to the other layer
    assert.equal(1, b.at)
    assert.is_true(a.cleared >= 1)

    mousemove.unregister(1111)
    mousemove.unregister(2222)
    assert.equal("", vim.fn.maparg("<MouseMove>", "n"))
  end)
end)
