-- Spatial navigation on the focused Fibrous canvas. Positions and distances below
-- are display cells. Convert to buffer byte columns only when placing the cursor.
local clip = require("fibrous.inline.clip")
local targets = require("fibrous.targets")
local M = { enabled = true }
local event = "FibrousWidgetModeChanged"

function M.toggle()
  M.enabled = not M.enabled
  vim.api.nvim_exec_autocmds("User", { pattern = event, modeline = false })
  vim.api.nvim_echo({ { "Fibrous widget mode " .. (M.enabled and "on" or "off") } }, false, {})
  return M.enabled
end

-- Neovim keymaps are buffer-local. A raw buffer can also be displayed in an
-- ordinary window, so lend the mapping to its buffer only while our window
-- has focus. Keep exact buffer-local mappings supplied by the app or user.
local windows = {}
local binding
local function unbind()
  if not binding then return end
  local old = binding
  binding = nil
  if vim.api.nvim_buf_is_valid(old.buf) then
    vim.api.nvim_buf_call(old.buf, function()
      if vim.fn.maparg(old.key, "n", false, true).callback == old.callback then
        vim.keymap.del("n", old.key, { buffer = old.buf })
      end
    end)
  end
end

local function bind_focused()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if binding and binding.win == win and binding.buf == buf then return end
  unbind()
  if windows[win] ~= buf then return end
  local key = vim.g.fibrous_widget_mode_key
  if key == nil then key = "<Leader>w" end
  if type(key) ~= "string" or key == "" then return end
  key = vim.fn.keytrans(vim.keycode(key))
  if vim.fn.maparg(key, "n", false, true).buffer == 1 then return end
  local function toggle()
    if windows[vim.api.nvim_get_current_win()] ~= vim.api.nvim_get_current_buf() then
      -- A :noautocmd focus change bypassed WinLeave. Replay with the ordinary
      -- window's mapping after releasing ours.
      unbind()
      vim.api.nvim_feedkeys(vim.keycode(key), "im", false)
      return
    end
    M.toggle()
  end
  vim.keymap.set("n", key, toggle, { buffer = buf, desc = "Fibrous: toggle widget mode" })
  binding = { win = win, buf = buf, key = key, callback = toggle }
end

local key_group = vim.api.nvim_create_augroup("FibrousWidgetKey", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "VimEnter" }, { group = key_group, callback = bind_focused })
vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, { group = key_group, callback = unbind })

function M.register_window(win, buf)
  windows[win] = buf
  if vim.api.nvim_get_current_win() == win then bind_focused() end
  return function()
    if windows[win] == buf then
      windows[win] = nil
      if binding and binding.win == win then unbind() end
    end
  end
end

local function clamp(value, start, size)
  return math.max(start, math.min(value, start + size - 1))
end

local function nearest(boxes, x, y, key, preferred)
  local current
  for _, target in ipairs(boxes) do
    if clip.contains(target.box, x, y) then current = target end
  end
  if current and not key then return x, y end

  local vertical = key == "j" or key == "k"
  local aim = vertical and preferred or x
  local best, best_x, best_y
  for _, target in ipairs(boxes) do
    local box = target.box
    local nx, ny = clamp(aim, box.x, box.w), clamp(y, box.y, box.h)
    local ahead = not key or (key == "j" and ny > y) or (key == "k" and ny < y)
      or (key == "l" and nx > x) or (key == "h" and nx < x)
    local same = current and current.node == target.node and current.span == target.span
    if ahead and not same then
      local score = (nx - aim) ^ 2 + (ny - y) ^ 2
      if not best or score < best then
        best, best_x, best_y = score, nx, ny
      end
    end
  end
  return best_x, best_y
end

local title = { { " WIDGET ", "FibrousWidgetMode" } }

-- A popup may focus a borderless scrolling child. Use the closest free
-- Fibrous border so the badge stays clear of the child's controls.
local function border_for_indicator(win)
  local seen = {}
  while win and not seen[win] and vim.api.nvim_win_is_valid(win) do
    seen[win] = true
    local config = vim.api.nvim_win_get_config(win)
    local top = type(config.border) == "table" and config.border[2]
    if type(top) == "table" then top = top[1] end
    if top and top ~= "" and not config.title then return win end
    win = vim.w[win].fibrous_anchor
  end
end

local function show_indicator(winid, group)
  local frame = border_for_indicator(winid)
  if frame then
    vim.api.nvim_win_set_config(frame, { title = title, title_pos = "right" })
    return function()
      if vim.api.nvim_win_is_valid(frame) and vim.deep_equal(vim.api.nvim_win_get_config(frame).title, title) then
        vim.api.nvim_win_set_config(frame, { title = "" })
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local label = "WIDGET"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label })
  local width = vim.api.nvim_win_get_width(winid)
  local badge = vim.api.nvim_open_win(buf, false, {
    relative = "win", win = winid, anchor = "NE", row = 0, col = width,
    width = math.min(width, #label), height = 1, border = "none",
    style = "minimal", focusable = false, noautocmd = true,
    zindex = math.max(99, (vim.api.nvim_win_get_config(winid).zindex or 0) + 1),
  })
  vim.wo[badge].winhighlight = "Normal:FibrousWidgetMode,NormalFloat:FibrousWidgetMode"
  local resize = vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(winid) or not vim.api.nvim_win_is_valid(badge) then return end
      local current = vim.api.nvim_win_get_width(winid)
      if current ~= width then
        width = current
        vim.api.nvim_win_set_config(badge, {
          relative = "win", win = winid, anchor = "NE", row = 0, col = width, width = math.min(width, #label),
        })
      end
    end,
  })
  return function()
    vim.api.nvim_del_autocmd(resize)
    if vim.api.nvim_win_is_valid(badge) then vim.api.nvim_win_close(badge, true) end
  end
end

---@param winid integer
---@param target FlushTarget
---@param subwins SubwinManager?
---@param cursor_cell fun(): integer?, integer?
---@param group integer
---@return {snap: fun(): boolean, teardown: fun()}
function M.attach(winid, target, subwins, cursor_cell, group)
  local buf = target.bufnr
  local saved_maps, hide_indicator
  local preferred, last_x, last_y

  local function move(key, count)
    local y, x = cursor_cell()
    if not y then return end
    local vertical = key == "j" or key == "k"
    if not vertical or x ~= last_x or y ~= last_y then preferred = x end

    -- A page motion has already positioned the viewport. Snap within it.
    -- Directional steps can reach the next widget beyond a viewport edge.
    local bounds
    if not key then
      local info = vim.fn.getwininfo(winid)[1]
      bounds = { x = vim.fn.winsaveview().leftcol, y = info.topline - 1,
        w = info.width - info.textoff, h = info.botline - info.topline + 1 }
    end
    local boxes = {}
    targets.visit_boxes(target.tree, function(node, box, run)
      box = clip.intersect(box, bounds)
      if box.w > 0 and box.h > 0 then
        boxes[#boxes + 1] = { box = box, node = node, span = run and run.id }
      end
    end, subwins and subwins.visit_subwindow)
    local old_y, old_x = y, x
    for _ = 1, count do
      local nx, ny = nearest(boxes, x, y, key, preferred)
      if not nx or (x == nx and y == ny) then break end
      x, y = nx, ny
    end
    if y ~= old_y or x ~= old_x then
      local byte = vim.fn.virtcol2col(winid, y + 1, x + 1)
      vim.api.nvim_win_set_cursor(winid, { y + 1, math.max(0, byte - 1) })
    end
    last_y, last_x = cursor_cell()
    if not vertical then preferred = last_x end
  end

  -- CursorMoved can be deferred while Neovim drains typeahead. Also settle
  -- the last native motion before using its destination in a mapped command.
  local function snap()
    if not saved_maps or vim.api.nvim_get_current_win() ~= winid then return false end
    local y, x = cursor_cell()
    if y ~= last_y or x ~= last_x then move(nil, 1) end
    return true
  end

  -- Only override these keys while widget mode is active. Ordinary Normal
  -- mode gets the app's and user's mappings, including buffer-local callbacks.
  local function leave()
    if not saved_maps then return end
    local restore = saved_maps
    saved_maps, preferred, last_x, last_y = nil, nil, nil, nil
    hide_indicator()
    hide_indicator = nil
    if vim.api.nvim_win_is_valid(winid) then vim.w[winid].fibrous_widget_mode = nil end
    vim.cmd("redrawstatus")
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_call(buf, function()
      for key, mapping in pairs(restore) do
        if vim.fn.maparg(key, "n", false, true).callback == mapping.callback then
          vim.keymap.del("n", key, { buffer = buf })
          if mapping.previous.buffer == 1 then vim.fn.mapset("n", false, mapping.previous) end
        end
      end
    end)
  end

  local function bind(key, callback, desc)
    saved_maps[key] = { previous = vim.fn.maparg(key, "n", false, true), callback = callback }
    vim.keymap.set("n", key, callback, { buffer = buf, nowait = true, desc = desc })
  end

  local function refresh()
    if not M.enabled or vim.api.nvim_get_current_win() ~= winid
      or vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_get_mode().mode ~= "n" then
      leave()
      return
    end
    if saved_maps then return end
    saved_maps = {}
    for _, key in ipairs({ "h", "j", "k", "l" }) do
      bind(key, function()
        snap()
        move(key, vim.v.count1)
      end, "fibrous: move to widget")
    end
    hide_indicator = show_indicator(winid, group)
    vim.w[winid].fibrous_widget_mode = true
    vim.cmd("redrawstatus")
    -- A buffer mount attaches its interaction before its first layout.
    if target.tree then snap() else vim.schedule(snap) end
  end

  vim.api.nvim_create_autocmd("User", { group = group, pattern = event, callback = refresh })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "ModeChanged" }, {
    group = group, buffer = buf, callback = refresh,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, { group = group, buffer = buf, callback = leave })
  refresh()

  local unregister = M.register_window(winid, buf)
  return { snap = snap, teardown = function()
    unregister()
    leave()
  end }
end

return M
