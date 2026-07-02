-- Cursor interaction for the inline host (tracker "NEW UI HOST" task 6). The
-- vim cursor IS the pointer: whatever interactive node the cursor sits in is
-- hovered, and <CR>/<Space> activate it. Everything works off the laid-out
-- tree the host keeps (host.tree — rects in buffer cell coordinates), so the
-- hit-map is a pure tree walk with no extra bookkeeping per commit.
--
--   hover      the deepest node under the cursor carrying a `role` gets its
--              border-box rect painted with props.hover_hl (default
--              "CursorLine") in a dedicated namespace; re-evaluated on
--              CursorMoved and after every flush (rects may have moved).
--   activate   <CR>/<Space>, buffer-local on the host buffer: role "button"
--              → on_press(); "checkbox" → on_toggle(not checked).

local M = {}

local width = require("fibrous.inline.width")
local char_width, str_width = width.char, width.str

local ns_hover = vim.api.nvim_create_namespace("fibrous_inline_hover")

-- Byte offset of display-cell column `cell` in `line` (for extmark cols; the
-- canvas guarantees one char per cell, wide chars head + "" continuation).
---@param line string
---@param cell integer
---@return integer
local function cell_to_byte(line, cell)
  local w, b = 0, 0
  for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if w >= cell then
      break
    end
    b = b + #ch
    w = w + char_width(ch)
  end
  return b
end

-- The deepest node at cell (x, y) carrying a role. Later children paint over
-- earlier ones, so they are tried in reverse; a role-less subtree falls
-- through to the closest interactive ancestor.
---@param node table  a node annotated by layout.compute
---@param x integer
---@param y integer
---@return table|nil
local function hit(node, x, y)
  local r = node.rect
  if not r or x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then
    return nil
  end
  local children = node.children or {}
  for i = #children, 1, -1 do
    local found = hit(children[i], x, y)
    if found then
      return found
    end
  end
  if node.props and node.props.role then
    return node
  end
  return nil
end

---@class InteractHandle
---@field update fun()    re-evaluate hover at the current cursor (called on CursorMoved and post-flush)
---@field teardown fun()

-- Attach cursor interaction to `host` displayed in the root float `root_winid`.
---@param host InlineHost
---@param root_winid integer
---@return InteractHandle
function M.attach(host, root_winid)
  local bufnr = host.bufnr
  local group = vim.api.nvim_create_augroup("FibrousInlineInteract_" .. root_winid, { clear = true })

  -- The interactive node under the root window's cursor, or nil.
  local function node_under_cursor()
    if not host.tree or not vim.api.nvim_win_is_valid(root_winid) then
      return nil
    end
    local pos = vim.api.nvim_win_get_cursor(root_winid)
    local row = pos[1] - 1
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local x = str_width(line:sub(1, pos[2])) -- byte col → display cell
    return hit(host.tree, x, row)
  end

  local function update()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
    local node = node_under_cursor()
    if not node then
      return
    end
    local r = node.rect
    local hl = node.props.hover_hl or "CursorLine"
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    for y = math.max(r.y, 0), math.min(r.y + r.h - 1, last) do
      local line = vim.api.nvim_buf_get_lines(bufnr, y, y + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(bufnr, ns_hover, y, cell_to_byte(line, r.x), {
        end_col = cell_to_byte(line, r.x + r.w),
        hl_group = hl,
        priority = 4200, -- above the canvas's base spans (default 4096)
      })
    end
  end

  local function activate()
    local node = node_under_cursor()
    if not node then
      return
    end
    local props = node.props
    if props.role == "button" and props.on_press then
      props.on_press()
    elseif props.role == "checkbox" and props.on_toggle then
      props.on_toggle(not props.checked)
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = update,
  })
  for _, lhs in ipairs({ "<CR>", "<Space>" }) do
    vim.keymap.set("n", lhs, activate, { buffer = bufnr, nowait = true, desc = "fibrous: activate" })
  end

  return {
    update = update,
    teardown = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
        for _, lhs in ipairs({ "<CR>", "<Space>" }) do
          pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
        end
      end
    end,
  }
end

return M
