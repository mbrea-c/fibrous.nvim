-- ui.dropdown: a singleline text_input plus a ui.popup listing the filtered
-- options. Focus opens the popup (normal or insert mode) showing ALL options
-- with the selection on the current value; typing filters (fuzzy by default)
-- and resets the selection to the best match; <C-n>/<C-p> move it (wrapping);
-- <CR>/<C-y> commit the selection into the field; <C-e> closes the popup
-- keeping the typed text uncommitted; unfocus commits the selection, and
-- free-standing typed text survives only under `free_text = true` (default is
-- strict select: no match on blur reverts to the last committed value).

local mount = require("fibrous.inline.mount")
local dd = require("fibrous.inline.dropdown")
local ui = require("fibrous.inline.components")

local ns = vim.api.nvim_create_namespace("fibrous_inline")

-- The dropdown's two floats: the input (focusable) and the popup (not).
local function floats_of(handle)
  local input, popup
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid then
      if vim.api.nvim_win_get_config(win).focusable == false then
        popup = win
      else
        input = win
      end
    end
  end
  return input, popup
end

local function popup_lines(handle)
  local _, popup = floats_of(handle)
  if not popup then
    return nil
  end
  return vim.tbl_map(function(l)
    return (l:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false))
end

-- 1-based row of the selection highlight in the popup buffer.
local function sel_row(handle)
  local _, popup = floats_of(handle)
  if not popup then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(popup)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == "FibrousPopupSel" then
      return m[2] + 1
    end
  end
  return nil
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

local function wait_for(cond)
  vim.wait(500, cond, 5)
  return cond()
end

local OPTIONS = { "apple", "apricot", "banana", "cherry" }

local function dd_app(props)
  return function()
    return {
      comp = ui.col,
      props = {},
      children = { { comp = ui.dropdown, props = props } },
    }
  end
end

describe("dropdown helpers", function()
  it("filter: empty text shows everything, otherwise fuzzy best-first", function()
    assert.same(OPTIONS, dd.filter(OPTIONS, ""))
    assert.same({ "apple", "apricot" }, dd.filter(OPTIONS, "ap"))
    assert.same({}, dd.filter(OPTIONS, "zzz"))
  end)

  it("window: top-anchored, slides to keep the selection on the last row", function()
    assert.equal(1, dd.window(4, 2, 8)) -- everything fits
    assert.equal(1, dd.window(20, 8, 8)) -- selection on the window's last row
    assert.equal(2, dd.window(20, 9, 8)) -- one past: slide by one
    assert.equal(13, dd.window(20, 20, 8)) -- bottom: window pinned to the tail
  end)

  it("blur_value: chosen wins; typed survives via free_text or exact match", function()
    assert.equal("apple", dd.blur_value("app", "apple", false, OPTIONS))
    assert.equal("app", dd.blur_value("app", nil, true, OPTIONS))
    assert.equal("banana", dd.blur_value("banana", nil, false, OPTIONS))
    assert.is_nil(dd.blur_value("app", nil, false, OPTIONS))
  end)
end)

describe("ui.dropdown", function()
  it("focus opens the popup with all options, selection on the current value", function()
    local handle = mount.floating(
      dd_app({ options = OPTIONS, value = "banana", width = 12 }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    assert.is_nil(select(2, floats_of(handle))) -- closed until focused

    vim.api.nvim_set_current_win(input)
    assert.is_true(wait_for(function()
      return popup_lines(handle) ~= nil
    end))
    assert.same(OPTIONS, popup_lines(handle))
    assert.equal(3, sel_row(handle)) -- banana

    handle.unmount()
  end)

  it("typing filters and resets the selection to the best match", function()
    local handle = mount.floating(
      dd_app({ options = OPTIONS, value = "", width = 12 }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    vim.api.nvim_set_current_win(input)
    press("iap")
    assert.is_true(wait_for(function()
      local lines = popup_lines(handle)
      return lines and #lines == 2
    end))
    assert.same({ "apple", "apricot" }, popup_lines(handle))
    assert.equal(1, sel_row(handle))

    -- no match: an inert placeholder row, nothing selected. (feedkeys "x"
    -- ended the previous batch's insert mode, so re-enter appending.)
    press("azzz")
    assert.is_true(wait_for(function()
      local lines = popup_lines(handle)
      return lines and lines[1] == "(no match)"
    end))
    assert.is_nil(sel_row(handle))

    handle.unmount()
  end)

  it("<C-n>/<C-p> move the selection (wrapping) and <CR> commits it", function()
    local selected = {}
    local handle = mount.floating(
      dd_app({
        options = OPTIONS,
        value = "",
        width = 12,
        on_select = function(v)
          selected[#selected + 1] = v
        end,
      }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    local ibuf = vim.api.nvim_win_get_buf(input)
    vim.api.nvim_set_current_win(input)
    assert.is_true(wait_for(function()
      return popup_lines(handle) ~= nil
    end))

    press("<C-n>") -- 1 -> 2
    assert.is_true(wait_for(function()
      return sel_row(handle) == 2
    end))
    press("<C-p>")
    press("<C-p>") -- 1 wraps to 4
    assert.is_true(wait_for(function()
      return sel_row(handle) == 4
    end))

    press("<CR>")
    assert.is_true(wait_for(function()
      return popup_lines(handle) == nil
    end))
    assert.same({ "cherry" }, vim.api.nvim_buf_get_lines(ibuf, 0, -1, false))
    assert.same({ "cherry" }, selected)

    handle.unmount()
  end)

  it("unfocus commits the current selection", function()
    local selected = {}
    local handle = mount.floating(
      dd_app({
        options = OPTIONS,
        value = "",
        width = 12,
        on_select = function(v)
          selected[#selected + 1] = v
        end,
      }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    local ibuf = vim.api.nvim_win_get_buf(input)
    vim.api.nvim_set_current_win(input)
    assert.is_true(wait_for(function()
      return popup_lines(handle) ~= nil
    end))
    press("<C-n>") -- apricot

    vim.api.nvim_set_current_win(handle.winid)
    assert.is_true(wait_for(function()
      return popup_lines(handle) == nil
    end))
    assert.same({ "apricot" }, vim.api.nvim_buf_get_lines(ibuf, 0, -1, false))
    assert.same({ "apricot" }, selected)

    handle.unmount()
  end)

  it("strict (default): <C-e> keeps typing uncommitted, blur reverts no-match text", function()
    local selected = {}
    local handle = mount.floating(
      dd_app({
        options = OPTIONS,
        value = "apple",
        width = 12,
        on_select = function(v)
          selected[#selected + 1] = v
        end,
      }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    local ibuf = vim.api.nvim_win_get_buf(input)
    vim.api.nvim_set_current_win(input)
    press("cczzz")
    assert.is_true(wait_for(function()
      local lines = popup_lines(handle)
      return lines and lines[1] == "(no match)"
    end))
    press("<C-e>")
    assert.is_true(wait_for(function()
      return popup_lines(handle) == nil
    end))
    assert.same({ "zzz" }, vim.api.nvim_buf_get_lines(ibuf, 0, -1, false))

    vim.api.nvim_set_current_win(handle.winid)
    assert.is_true(wait_for(function()
      return vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)[1] == "apple"
    end))
    assert.same({}, selected) -- a revert is not a selection

    handle.unmount()
  end)

  it("free_text = true: typed text matching no option survives blur", function()
    local selected = {}
    local handle = mount.floating(
      dd_app({
        options = OPTIONS,
        value = "",
        width = 12,
        free_text = true,
        on_select = function(v)
          selected[#selected + 1] = v
        end,
      }),
      {},
      { width = 14, height = 2, row = 2, col = 2 }
    )
    local input = floats_of(handle)
    local ibuf = vim.api.nvim_win_get_buf(input)
    vim.api.nvim_set_current_win(input)
    press("izzz")
    assert.is_true(wait_for(function()
      local lines = popup_lines(handle)
      return lines and lines[1] == "(no match)"
    end))

    vim.api.nvim_set_current_win(handle.winid)
    assert.is_true(wait_for(function()
      return popup_lines(handle) == nil
    end))
    assert.same({ "zzz" }, vim.api.nvim_buf_get_lines(ibuf, 0, -1, false))
    assert.same({ "zzz" }, selected)

    handle.unmount()
  end)
end)
