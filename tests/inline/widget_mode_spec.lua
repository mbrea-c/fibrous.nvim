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
  local wm = require("fibrous.inline.widget_mode")
  local previous_leader, previous_enabled
  before_each(function()
    previous_enabled = wm.enabled
    if wm.enabled then wm.toggle() end
    previous_leader = vim.g.mapleader
    vim.g.mapleader = " "
    vim.cmd("runtime plugin/fibrous.lua")
  end)
  after_each(function()
    if wm.enabled ~= previous_enabled then wm.toggle() end
    vim.g.mapleader = previous_leader
  end)

  it("shares the toggle between Fibrous views and leaves ordinary buffers to their bindings", function()
    local editor = vim.api.nvim_get_current_win()
    assert.equal("", vim.fn.maparg("<Leader>w", "n"))
    assert.equal("", vim.fn.maparg("gW", "n"))
    local calls = 0
    vim.keymap.set("n", "<Leader>w", function() calls = calls + 1 end)
    local a = view({ item("one"), gap("plain"), item("two") })
    press("<Leader>w")
    assert.equal(0, calls)
    assert.is_true(vim.w[a.winid].fibrous_widget_mode)
    local b = view({ item("first"), gap("plain"), item("last") })
    press("j")
    assert.same({ 3, 0 }, pos())
    press("<Esc>")
    assert.is_true(vim.w[b.winid].fibrous_widget_mode)
    vim.api.nvim_set_current_win(editor)
    press("<Leader>w")
    assert.equal(1, calls)
    vim.api.nvim_set_current_win(a.winid)
    assert.is_true(vim.w[a.winid].fibrous_widget_mode)
    press("<Leader>w")
    vim.keymap.del("n", "<Leader>w")
    assert.is_nil(vim.w[a.winid].fibrous_widget_mode)
    press("j")
    assert.same({ 2, 0 }, pos())
    b.unmount()
    a.unmount()
  end)
  it("applies a preexisting preference to a newly mounted buffer before its first motion", function()
    vim.cmd.FibrousToggleWidgetMode()
    local app_calls = 0
    local h = mount.buffer(function()
      return { comp = ui.col, props = { on_key = { j = function() app_calls = app_calls + 1 end } },
        children = { gap("inert"), item("one"), gap("inert"), item("two") } }
    end, {}, { keys = { "j" } })
    press("j")
    assert.same({ 4, 0 }, pos())
    assert.equal(0, app_calls)
    press("<Leader>wj")
    assert.equal(1, app_calls)
    h.unmount()
  end)

  it("publishes the active root window until widget mode exits", function()
    local previous = vim.api.nvim_get_current_win()
    local h = view({ gap("no controls here") })
    local count = #vim.api.nvim_list_wins()
    local function active() return vim.w[h.winid].fibrous_widget_mode end
    assert.is_nil(active())
    press("<Leader>w")
    assert.is_true(active())
    assert.is_nil(vim.w[previous].fibrous_widget_mode)
    assert.equal(h.winid, vim.api.nvim_get_current_win())
    press("<Leader>w")
    assert.is_nil(active())
    assert.equal(count, #vim.api.nvim_list_wins())
    press("<Leader>wv<Esc>")
    assert.is_true(active())
    vim.api.nvim_set_current_win(previous)
    assert.is_nil(active())
    assert.equal(count, #vim.api.nvim_list_wins())
    h.unmount()
  end)

  it("preserves app-owned float titles and removes the overlay on unmount", function()
    local h = mount.floating(function() return gap("page") end, {}, { width = 24, height = 4, border = "rounded" })
    vim.api.nvim_set_current_win(h.winid)
    local title = { { "Help", "Title" } }
    vim.api.nvim_win_set_config(h.winid, { title = title, title_pos = "center" })
    local windows = #vim.api.nvim_list_wins()
    press("<Leader>w")
    assert.same(title, vim.api.nvim_win_get_config(h.winid).title)
    assert.equal(windows + 1, #vim.api.nvim_list_wins())
    h.unmount()
    assert.equal(windows - 1, #vim.api.nvim_list_wins())
  end)

  it("starts with WIDGET visible and keeps the toggle setting across mounts in a real terminal", function()
    local log = vim.fn.tempname()
    require("fibrous.bench.termdraw").drive({
      rtp = { vim.fn.getcwd() },
      init = [[
        vim.o.ttimeoutlen = 10
        vim.o.timeoutlen = 350
        vim.g.mapleader = " "
        local mount = require("fibrous.inline.mount")
        local ui = require("fibrous.inline.components")
        local child
        local function page()
          return { comp = ui.col, children = {
            { comp = ui.label, props = { text = "page" } },
            { comp = ui.container, props = { height = 2, on_create = function(_, win) child = win end },
              children = { { comp = ui.button, props = { label = "select" } } } },
          } }
        end
        local h = mount.floating(page, {}, { width = 28, height = 6, border = "rounded" })
        vim.api.nvim_set_current_win(h.winid)
        vim.keymap.set("n", "Q", function()
          local pos = vim.fn.screenpos(h.winid, 1, 1)
          local width = vim.api.nvim_win_get_width(h.winid)
          local found = "absent"
          for y = math.max(1, pos.row - 1), pos.row do
            local line = ""
            for x = pos.col, pos.col + width - 1 do
              line = line .. vim.fn.screenstring(y, x)
            end
            if line:sub(-9):find("WIDGET", 1, true) then
              found = y < pos.row and "border" or "corner"
            end
          end
          if vim.api.nvim_get_current_win() == child then found = "child:" .. found end
          vim.fn.writefile({ found }, ]] .. string.format("%q", log) .. [[, "a")
        end)
        vim.keymap.set("n", "B", function()
          h.unmount()
          vim.cmd("vsplit")
          h = mount.buffer(page, {}, {})
        end)
        vim.keymap.set("n", "R", function() vim.cmd("vertical resize 25") end)
      ]],
      steps = {
        { send = "Q", wait_ms = 30 },
        { send = "\r", wait_ms = 80 }, { send = "Q", wait_ms = 30 },
        { send = "\027", wait_ms = 80 },
        { send = " ", wait_ms = 50 }, { send = "w", wait_ms = 100 }, { send = "Q", wait_ms = 30 },
        { send = "B", wait_ms = 100 }, { send = "Q", wait_ms = 30 },
        { send = " w", wait_ms = 100 }, { send = "Q", wait_ms = 30 },
        { send = "R", wait_ms = 100 }, { send = "Q", wait_ms = 30 },
        { send = " w", wait_ms = 100 }, { send = "Q", wait_ms = 30 },
      },
    })
    local seen = vim.fn.readfile(log)
    vim.fn.delete(log)
    assert.same({ "border", "child:border", "absent", "absent", "corner", "corner", "absent" }, seen)
  end)

  it("snaps on <Leader>w and walks rectangles, keeping the column across uneven rows", function()
    local handle = view({
      row({ item("one"), gap("   "), item("two") }),
      item("x"), gap("inert"), row({ item("end"), gap("   "), item("six") }),
    })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    press("<Leader>w")
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
    press("<Leader>wl")
    assert.same({ 1, 3 }, pos())
    handle.unmount()
  end)

  it("keeps the preference through activation, visual mode and search", function()
    local presses = 0
    local function activate() presses = presses + 1 end
    local handle = view({ item("aaa", activate), gap("gap"), item("bbb", activate) })
    press("<Leader>w<Space>j")
    assert.equal(1, presses)
    assert.is_true(vim.w[handle.winid].fibrous_widget_mode)
    assert.same({ 3, 0 }, pos())
    press("<CR>k")
    assert.equal(2, presses)
    assert.is_true(vim.w[handle.winid].fibrous_widget_mode)
    assert.same({ 1, 0 }, pos())
    press("v<Esc>j")
    assert.same({ 3, 0 }, pos())
    press("/gap<CR>")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    assert.is_true(vim.w[handle.winid].fibrous_widget_mode)
    assert.is_true(pos()[1] ~= 2)
    handle.unmount()
  end)

  it("snaps native landings to interactive spans in display cells", function()
    local handle = view({
      { comp = ui.paragraph, props = { text = { "界 ", { "link", role = "link" }, " inert" } } },
      gap("blank"),
    })
    press("<Leader>w")
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
    press("<Leader>wlh")
    assert.same({ 1, 0 }, pos())
    handle.unmount()
  end)

  it("snaps a queued native motion before acting on its destination", function()
    local called = 0
    local handle = view({ item("first"), gap("inert"), item("last", function() called = called + 1 end), gap("tail") })
    press("<Leader>wG<Space>")
    assert.equal(1, called)
    press("ggG<CR>")
    assert.equal(2, called)
    assert.same({ 3, 0 }, pos())
    handle.unmount()
  end)

  it("keeps editing native inside the field and resumes on return", function()
    local handle = view({ item("top"), gap("gap"), { comp = ui.text_input, props = { value = "abcd" } } })
    press("<Leader>wjiX<Esc>")
    assert.is_true(vim.api.nvim_get_current_win() ~= handle.winid)
    assert.equal("Xabcd", vim.api.nvim_get_current_line())
    assert.is_nil(vim.w.fibrous_widget_mode)
    press("<Leader>w")
    assert.is_false(require("fibrous.inline.widget_mode").enabled)
    press("<Leader>w")
    assert.is_true(require("fibrous.inline.widget_mode").enabled)
    press("<Esc>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    press("k")
    assert.same({ 1, 0 }, pos())
    handle.unmount()
  end)

  it("scopes a shared raw buffer's shortcut to its Fibrous window", function()
    local ordinary = vim.api.nvim_get_current_win()
    local raw = vim.api.nvim_get_current_buf()
    local h = view({ { comp = ui.raw_buffer, props = { bufnr = raw, height = 2 } } })
    press("<CR>")
    assert.equal(raw, vim.api.nvim_get_current_buf())
    assert.is_true(vim.api.nvim_get_current_win() ~= ordinary)
    press("<Leader>w")
    assert.is_true(require("fibrous.inline.widget_mode").enabled)
    vim.api.nvim_set_current_win(ordinary)
    assert.equal("", vim.fn.maparg("<Leader>w", "n"))
    vim.keymap.set("n", "<Leader>w", "<Nop>", { buffer = raw })
    vim.api.nvim_set_current_win(h.winid)
    press("<CR>")
    assert.equal("<Nop>", vim.fn.maparg("<Leader>w", "n"))
    press("<Leader>w")
    assert.is_true(require("fibrous.inline.widget_mode").enabled)
    h.unmount()
    assert.equal("<Nop>", vim.fn.maparg("<Leader>w", "n"))
    vim.keymap.del("n", "<Leader>w", { buffer = raw })
  end)

  it("honors a custom Return mapping while navigation stays active", function()
    local handle = view({ item("one"), gap("gap"), item("two") })
    local calls = 0
    vim.keymap.set("n", "<CR>", function() calls = calls + 1 end, { buffer = handle.bufnr })
    press("<Leader>w<CR>j")
    assert.equal(1, calls)
    assert.same({ 3, 0 }, pos())
    handle.unmount()
  end)

  it("snaps a half-page motion in its new viewport in a real terminal", function()
    local log = vim.fn.tempname()
    require("fibrous.bench.termdraw").drive({
      rtp = { vim.fn.getcwd() },
      init = [[
        vim.o.ttimeoutlen = 10
        vim.o.timeoutlen = 350
        vim.g.mapleader = " "
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
    press("<Leader>wj<Leader>wj")
    assert.equal(1, called)
    assert.same({ 2, 0 }, pos())
    handle.unmount()
  end)

  it("navigates controls inside a container while focus stays on the root", function()
    local pressed = 0
    local handle = view({ item("top"), { comp = ui.container, props = { height = 3 },
      children = { gap("first"), item("inside", function() pressed = pressed + 1 end), item("next") } } })
    press("<Leader>wj")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    assert.same({ 3, 0 }, pos())
    press("<Space>")
    assert.equal(1, pressed)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    press("<CR>")
    assert.equal(2, pressed)
    assert.is_true(vim.w.fibrous_widget_mode)
    press("j")
    assert.same({ 3, 0 }, pos())
    press("<Esc>")
    assert.equal(handle.winid, vim.api.nvim_get_current_win())
    handle.unmount()
  end)
end)
