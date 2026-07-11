-- Interactive spans in the cursor layer (markdown-widget foundation, phase 1b).
-- A span carrying `on_click` fires on <CR>/<Space>/click when the cursor is on
-- it, exactly like a button; a span carrying `_hover` (or on_click) paints a
-- hover overlay in its own namespace over EVERY run the span wrapped into, so a
-- link that breaks across lines lights up whole. All headless-safe: it inspects
-- the handler side effect and the extmark placement, not a redraw.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- Extmark spans with the given hl group, as { row, col, end_col } triples.
local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  table.sort(out, function(a, b)
    return a.row < b.row or (a.row == b.row and a.col < b.col)
  end)
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

describe("inline.interact interactive spans", function()
  it("fires on_click on <CR> and <Space> when the cursor is on the span", function()
    local clicks = 0
    local function App()
      return {
        comp = ui.paragraph,
        props = {
          text = {
            "click ",
            { "here", on_click = function()
              clicks = clicks + 1
            end, role = "link" },
            " now",
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 20, height = 3 })

    move_cursor(handle, 1, 2) -- on "click", not the link
    press(handle, "<CR>")
    assert.equal(0, clicks)

    move_cursor(handle, 1, 7) -- on "here"
    press(handle, "<CR>")
    assert.equal(1, clicks)
    press(handle, "<Space>")
    assert.equal(2, clicks)

    handle.unmount()
  end)

  it("paints a hover overlay over the span, and clears it moving off", function()
    local function App()
      return {
        comp = ui.paragraph,
        props = {
          text = {
            "go ",
            { "there", style = { _hover = { text_hl = "Search" } }, on_click = function() end },
            " ok",
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 20, height = 3 })

    move_cursor(handle, 1, 4) -- on "there" (cells 3..8)
    assert.same({ { row = 0, col = 3, end_col = 8 } }, marks_with(handle.bufnr, "Search"))

    move_cursor(handle, 1, 0) -- on "go"
    assert.same({}, marks_with(handle.bufnr, "Search"))

    handle.unmount()
  end)

  it("highlights every fragment of a span that wrapped across lines", function()
    local function App()
      return {
        comp = ui.paragraph,
        props = {
          -- one interactive span that will wrap into "aaaa" / "bbbb"
          text = {
            { "aaaa bbbb", style = { _hover = { text_hl = "Search" } }, on_click = function() end },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 4, height = 3 })

    move_cursor(handle, 1, 0) -- on "aaaa"
    -- both wrapped fragments light up, not just the one under the cursor
    assert.same({
      { row = 0, col = 0, end_col = 4 },
      { row = 1, col = 0, end_col = 4 },
    }, marks_with(handle.bufnr, "Search"))

    handle.unmount()
  end)
end)
