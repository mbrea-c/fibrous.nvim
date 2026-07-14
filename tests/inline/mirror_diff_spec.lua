-- The mirror repaint must be row-diffed (requests.md: "Transcript streaming
-- also causes full redraws even if there's no scroll, when it presumably
-- should be an append-only operation").
--
-- mirror() used to rewrite EVERY box row via set_text on each sync, even when
-- the row's cells were unchanged. Beyond the wasted writes, this hits an nvim
-- compositor edge: rewriting the line the CURRENT window's cursor sits on, in
-- the same tick as a change to the float covering it, forces a full re-
-- composition of the float — ~a full-float terminal repaint per streamed
-- append while the user's cursor is parked over the transcript (measured
-- ~950 B/append vs ~100 append-only). An append must only write the mirror
-- rows whose content actually changed.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function rows(n)
  local out = {}
  for i = 1, n do
    out[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } }
  end
  return out
end

-- Count nvim_buf_set_text calls into `bufnr` while `fn` runs.
local function count_set_text(bufnr, fn)
  local n = 0
  local orig = vim.api.nvim_buf_set_text
  vim.api.nvim_buf_set_text = function(buf, ...)
    if buf == bufnr then
      n = n + 1
    end
    return orig(buf, ...)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_buf_set_text = orig
  assert(ok, err)
  return n
end

describe("inline mirror row-diffing", function()
  it("an append inside a container rewrites only the changed mirror rows", function()
    local count = 3
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "header" } },
          { comp = ui.container, props = { height = 16, scroll_x = false }, children = rows(count) },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 50, height = 20, mode = "scroll" })
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 3, 0 }) -- parked over the mirror

    local writes = count_set_text(handle.bufnr, function()
      count = 4 -- one appended row; the 15 other box rows are untouched
      handle.set_props({})
    end)

    assert.is_true(
      writes <= 2,
      ("append rewrote %d mirror rows (want only the changed one — every extra write risks the cursor line and a full-float recomposite)"):format(writes)
    )
    handle.unmount()
  end)

  it("a flush that changes nothing in the container writes no mirror rows", function()
    local tick = 0
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "tick " .. tick } },
          { comp = ui.container, props = { height = 16, scroll_x = false }, children = rows(3) },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 50, height = 20, mode = "scroll" })
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 3, 0 })

    local writes = count_set_text(handle.bufnr, function()
      for i = 1, 3 do -- bystander animation flushes; container content is static
        tick = i
        handle.set_props({})
      end
    end)

    assert.equal(0, writes, "static container mirror rewritten " .. writes .. " times across no-change flushes")
    handle.unmount()
  end)
end)
