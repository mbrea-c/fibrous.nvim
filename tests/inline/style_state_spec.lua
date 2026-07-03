-- State-driven styling through the whole inline pipeline (tracker "Style
-- rework" S2): the `style` prop feeds layout + paint via style.normalize at
-- build time, and interaction states resolve at paint time —
--   hover  (interact.lua)  hl-only overrides paint as overlay extmarks with
--          no relayout; structural overrides set host state and relayout, so
--          the hover style is baked into the canvas;
--   focus  (subwin.lua)    a subwindow float gaining/losing the cursor applies
--          `_focus` via host state + relayout (focus changes are rare — no
--          fast path needed).

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Extmark spans with the given hl group (any namespace), as row/col triples.
local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

-- Put the cursor at (row, col) [1-based row] in the root float and re-evaluate
-- hover the way live cursor movement does.
local function move_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

-- The subwindow float (zindex 60, above the root's 50).
local function subwin_float()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).zindex == 60 then
      return w
    end
  end
end

describe("inline.style base wiring", function()
  it("style.border drives layout and paint like the flat prop", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "ab", style = { border = "single" } } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3 })

    assert.same({ "┌──────┐", "│ab    │", "└──────┘" }, lines_of(handle.bufnr))

    handle.unmount()
  end)

  it("style.hl fills the node's rect (background)", function()
    local function App()
      return { comp = ui.label, props = { text = "ab", style = { hl = "Search" } } }
    end
    local handle = mount.floating(App, {}, { width = 6, height = 1 })

    assert.same({ { row = 0, col = 0, end_col = 6 } }, marks_with(handle.bufnr, "Search"))

    handle.unmount()
  end)
end)

describe("inline.style hover states", function()
  it("an hl-only _hover paints as an overlay without touching the canvas", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "title" } },
          { comp = ui.button, props = { label = "OK", style = { _hover = { hl = "Visual" } } } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })
    local before = lines_of(handle.bufnr)

    move_cursor(handle, 2, 0) -- the button row
    assert.same({ { row = 1, col = 0, end_col = 6 } }, marks_with(handle.bufnr, "Visual"))
    assert.same(before, lines_of(handle.bufnr)) -- no relayout, buffer untouched

    move_cursor(handle, 1, 0)
    assert.same({}, marks_with(handle.bufnr, "Visual"))

    handle.unmount()
  end)

  it("a structural _hover relayouts: the border restyles under the cursor", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.button,
            props = { label = "OK", style = { border = "single", _hover = { border = "double" } } },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })
    assert.is_not_nil(lines_of(handle.bufnr)[2]:find("┌", 1, true))

    move_cursor(handle, 3, 0) -- inside the button's border box
    local hovered = lines_of(handle.bufnr)
    assert.is_not_nil(hovered[2]:find("╔", 1, true))
    assert.is_nil(hovered[2]:find("┌", 1, true))

    move_cursor(handle, 1, 0) -- off the button: base border returns
    assert.is_not_nil(lines_of(handle.bufnr)[2]:find("┌", 1, true))

    handle.unmount()
  end)
end)

describe("inline.style focus state", function()
  it("focusing a text_input float applies _focus; unfocusing clears it", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.text_input,
            props = { style = { border = "single", _focus = { border_hl = "Title" } } },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 4 })
    assert.same({}, marks_with(handle.bufnr, "Title"))

    local float = subwin_float()
    assert.is_not_nil(float)
    vim.api.nvim_set_current_win(float) -- WinEnter → focus state → relayout
    assert.is_true(#marks_with(handle.bufnr, "Title") > 0)

    vim.api.nvim_set_current_win(handle.winid) -- WinLeave → cleared
    assert.same({}, marks_with(handle.bufnr, "Title"))

    handle.unmount()
  end)
end)
