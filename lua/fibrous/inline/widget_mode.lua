-- Spatial navigation on the toplevel canvas. Positions and distances below
-- are display cells. Convert to buffer byte columns only when placing the cursor.
local clip = require("fibrous.inline.clip")
local targets = require("fibrous.targets")
local M = {}

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

---@param winid integer
---@param target FlushTarget
---@param subwins SubwinManager?
---@param cursor_cell fun(): integer?, integer?
---@param group integer
---@return {snap: fun(): boolean, leave: fun()}
function M.attach(winid, target, subwins, cursor_cell, group)
  local buf = target.bufnr
  local saved_maps
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
    if not saved_maps then return false end
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

  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_get_current_win() ~= winid then
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "in", false)
    elseif saved_maps then
      snap()
      leave()
    else
      saved_maps = {}
      for _, key in ipairs({ "h", "j", "k", "l" }) do
        bind(key, function()
          snap()
          move(key, vim.v.count1)
        end, "fibrous: move to widget")
      end
      bind("<CR>", function()
        local count = vim.v.count
        snap()
        leave()
        -- Replay the original map ahead of any remaining typeahead.
        vim.api.nvim_feedkeys((count > 0 and count or "") .. vim.keycode("<CR>"), "im", false)
      end, "fibrous: leave widget mode and activate")
      move(nil, 1)
    end
  end, { buffer = buf, nowait = true, desc = "fibrous: toggle widget mode" })

  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "ModeChanged" }, {
    group = group, buffer = buf, callback = function(ev)
      if ev.event ~= "ModeChanged" or vim.v.event.new_mode ~= "n" then leave() end
    end,
  })

  return { snap = snap, leave = leave }
end

return M
