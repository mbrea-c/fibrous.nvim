local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function pos()
  return vim.api.nvim_win_get_cursor(0)
end

local function item(text, action)
  return { comp = ui.label, props = { text = text, width = #text, role = "button", on_press = action } }
end

local function gap(text)
  return { comp = ui.label, props = { text = text } }
end

local function row(children)
  return { comp = ui.row, children = children }
end

local function view(children)
  local handle = mount.floating(function()
    return { comp = ui.col, children = children }
  end, {}, { width = 24, height = 8 })
  vim.api.nvim_set_current_win(handle.winid)
  return handle
end

describe("widget mode", function()
  it("snaps on Escape and walks rectangles, keeping the column across uneven rows", function()
    local handle = view({
      row({ item("one"), gap("   "), item("two") }),
      item("x"), gap("inert"), row({ item("end"), gap("   "), item("six") }),
    })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    press("<Esc>")
    assert.same({ 1, 2 }, pos())
    press("l")
    assert.same({ 1, 6 }, pos())
    press("2j")
    assert.same({ 4, 6 }, pos())
    press("j")
    assert.same({ 4, 6 }, pos())
    press("h")
    assert.same({ 4, 2 }, pos())
    press("2k")
    assert.same({ 1, 2 }, pos())
    press("<Esc>l")
    assert.same({ 1, 3 }, pos())
    handle.unmount()
  end)

  it("keeps Space in widget mode and exits on activation, visual mode and search", function()
    local presses = 0
    local function activate() presses = presses + 1 end
    local handle = view({ item("aaa", activate), gap("gap"), item("bbb", activate) })
    press("<Esc><Space>j")
    assert.equal(1, presses)
    assert.same({ 3, 0 }, pos())
    press("<CR>k")
    assert.equal(2, presses)
    assert.same({ 2, 0 }, pos())
    press("<Esc>v<Esc>j")
    assert.same({ 2, 0 }, pos())
    press("<Esc>/gap<CR>")
    assert.same({ 2, 0 }, pos())
    press("l")
    assert.same({ 2, 1 }, pos())
    handle.unmount()
  end)

  it("snaps native landings to interactive spans in display cells", function()
    local handle = view({
      { comp = ui.paragraph, props = { text = { "界 ", { "link", role = "link" }, " inert" } } },
      gap("blank"),
    })
    press("<Esc>")
    assert.same({ 1, 4 }, pos())
    press("$")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.same({ 1, 7 }, pos())
    handle.unmount()
  end)

  it("lands on the wide glyph when approached from its right", function()
    local handle = view({ { comp = ui.paragraph, props = { text = {
      { "界", role = "link" }, " gap ", { "x", role = "link" },
    } } } })
    press("<Esc>lh")
    assert.same({ 1, 0 }, pos())
    handle.unmount()
  end)

  it("snaps a queued native motion before acting on its destination", function()
    local called = 0
    local handle = view({ item("first"), gap("inert"), item("last", function() called = called + 1 end), gap("tail") })
    press("<Esc>G<Space>")
    assert.equal(1, called)
    press("ggG<CR>")
    assert.equal(2, called)
    assert.same({ 3, 0 }, pos())
    handle.unmount()
  end)

  it("keeps editing inside the field native and requires a fresh Escape at the root", function()
    local handle = view({ item("top"), gap("gap"), { comp = ui.text_input, props = { value = "abcd" } } })
    press("<Esc>jiX<Esc>")
    assert.is_true(vim.api.nvim_get_current_win() ~= handle.winid)
    assert.equal("Xabcd", vim.api.nvim_get_current_line())
    press("<Esc>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    press("k")
    assert.same({ 2, 0 }, pos())
    handle.unmount()
  end)

  it("exits before invoking a custom Return mapping", function()
    local handle = view({ item("one"), gap("gap"), item("two") })
    local calls = 0
    vim.keymap.set("n", "<CR>", function() calls = calls + 1 end, { buffer = handle.bufnr })
    press("<Esc><CR>j")
    assert.equal(1, calls)
    assert.same({ 2, 0 }, pos())
    handle.unmount()
  end)

  it("snaps a half-page motion in its new viewport in a real terminal", function()
    local log = vim.fn.tempname()
    require("fibrous.bench.termdraw").drive({
      rtp = { vim.fn.getcwd() },
      init = [[
        vim.o.ttimeoutlen = 10
        vim.o.scrolloff = 0
        local ui = require("fibrous.inline.components")
        local rows = {}
        for i = 1, 40 do
          rows[i] = { comp = ui.label, props = {
            text = "row " .. i, role = (i == 17 or i == 23) and "button" or nil,
          } }
        end
        local h = require("fibrous.inline.mount").floating(function()
          return { comp = ui.col, children = rows }
        end, {}, { width = 24, height = 8, mode = "scroll" })
        vim.api.nvim_set_current_win(h.winid)
        vim.api.nvim_win_set_cursor(0, { 23, 0 })
        vim.cmd("normal! zt")
        vim.keymap.set("n", "Q", function()
          vim.fn.writefile({ tostring(vim.fn.line(".")) }, ]] .. string.format("%q", log) .. [[, "a")
        end, { buffer = h.bufnr })
      ]],
      steps = {
        { send = "\027", wait_ms = 120 },
        { send = "8\021", wait_ms = 120 },
        { send = "Q", wait_ms = 80 },
        { send = "\021", wait_ms = 120 },
        { send = "Q", wait_ms = 80 },
      },
    })
    local rows = vim.fn.readfile(log)
    vim.fn.delete(log)
    assert.same({ "17", "9" }, rows)
  end)

  it("restores a buffer-local motion mapping on exit", function()
    local handle = view({ item("one"), item("two") })
    local called = 0
    vim.keymap.set("n", "j", function() called = called + 1 end, { buffer = handle.bufnr })
    press("<Esc>j<Esc>j")
    assert.equal(1, called)
    assert.same({ 2, 0 }, pos())
    handle.unmount()
  end)

  it("navigates controls inside a container while focus stays on the root", function()
    local pressed = 0
    local handle = view({ item("top"), { comp = ui.container, props = { height = 3 },
      children = { gap("first"), item("inside", function() pressed = pressed + 1 end) } } })
    press("<Esc>j")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 3, 0 }, pos())
    press("<Space>")
    assert.equal(1, pressed)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    press("<CR>")
    assert.equal(2, pressed)
    press("<Esc>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    handle.unmount()
  end)
end)
