-- Cursor interaction for the inline host (tracker "NEW UI HOST" task 6 +
-- "Style rework" S2). The vim cursor IS the pointer: whatever interactive
-- node the cursor sits in is hovered, and <CR>/<Space> activate it.
-- Everything works off the laid-out tree the host keeps (host.tree — rects in
-- buffer cell coordinates), so the hit-map is a pure tree walk with no extra
-- bookkeeping per commit.
--
--   hover      the deepest node under the cursor carrying a `role` takes its
--              `style._hover` override (default { hl = "FibrousHover" };
--              `hover_hl` is sugar for the hl key). hl-only overrides paint
--              as overlay extmarks in a dedicated namespace — no relayout;
--              a structural override records hover on the host and relayouts,
--              baking the hover style into the canvas. Re-evaluated on
--              CursorMoved and after every flush (rects may have moved).
--   activate   <CR>/<Space>, buffer-local on the host buffer: role "button"
--              → on_press(); "checkbox" → on_toggle(not checked). <CR> (and
--              clicks) first offer the cell to the subwindow manager —
--              subwindows are focused explicitly, never by traversal — and
--              i/I/a/A/o/O over a subwindow focus it and replay the key
--              inside, so "type here" costs one keystroke. <Space> stays
--              role-only (it is too common a motion to swallow into editors).
--   mouse      Neovim's own mouse=nvi handling moves the cursor on click, so
--              hover already follows clicks with no code here. On top of that
--              (tracker task 10, `opts.mouse`):
--                activate (default true)   <LeftRelease> fires the same
--                  activate path as <CR>. Release, not press: a drag lands in
--                  visual mode where the normal-mode map doesn't apply, so
--                  drag-selections never activate.
--                follow (default false)    focus-follows-mouse: <MouseMove>
--                  moves the cursor to the pointer, dragging hover along —
--                  one focus concept, two ways to move it. Opt-in because it
--                  needs the global 'mousemoveevent' (saved and restored).

local M = {}

local width = require("fibrous.inline.width")
local style = require("fibrous.inline.style")
local str_width, cell_to_byte = width.str, width.cell_to_byte

local ns_hover = vim.api.nvim_create_namespace("fibrous_inline_hover")

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

---@class InlineMouseOpts
---@field activate? boolean  click (<LeftRelease>) activates; default true
---@field follow? boolean    focus-follows-mouse via <MouseMove>; default false

-- Attach cursor interaction to `host` displayed in the root float `root_winid`.
---@param host InlineHost
---@param root_winid integer
---@param mouse? InlineMouseOpts|false  false disables all mouse maps
---@param subwins? SubwinManager  explicit-focus target for <CR>/click/insert keys
---@return InteractHandle
function M.attach(host, root_winid, mouse, subwins)
  if mouse == false then
    mouse = { activate = false, follow = false }
  else
    mouse = vim.tbl_extend("keep", mouse or {}, { activate = true, follow = false })
  end
  local bufnr = host.bufnr
  local group = vim.api.nvim_create_augroup("FibrousInlineInteract_" .. root_winid, { clear = true })

  -- The root cursor as a buffer cell (row, x), both 0-indexed; nil when the
  -- root window is gone.
  local function cursor_cell()
    if not vim.api.nvim_win_is_valid(root_winid) then
      return nil
    end
    local pos = vim.api.nvim_win_get_cursor(root_winid)
    local row = pos[1] - 1
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return row, str_width(line:sub(1, pos[2])) -- byte col → display cell
  end

  -- The interactive node under the root window's cursor, or nil.
  local function node_under_cursor()
    if not host.tree then
      return nil
    end
    local row, x = cursor_cell()
    if not row then
      return nil
    end
    return hit(host.tree, x, row)
  end

  -- The node's hover override; every interactive node hovers, so no override
  -- means the themed default (hover_hl sugar arrives here via normalize).
  local function hover_part(node)
    return (node.style and node.style.hover) or { hl = "FibrousHover" }
  end

  -- One overlay extmark span at cell range [x0, x1) of row y.
  local function mark(y, x0, x1, hl)
    local line = vim.api.nvim_buf_get_lines(bufnr, y, y + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns_hover, y, cell_to_byte(line, x0), {
      end_col = cell_to_byte(line, x1),
      hl_group = hl,
      priority = 4200, -- above the canvas's base spans (default 4096)
    })
  end

  -- Paint the hl-tier hover overlay for `node` (structural hovers were baked
  -- into the canvas by the relayout, so there is nothing left to overlay).
  local function paint(node)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
    if not node then
      return
    end
    local part = hover_part(node)
    if style.tier(part) == "structural" then
      return
    end
    local r = node.rect
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    local y0, y1 = math.max(r.y, 0), math.min(r.y + r.h - 1, last)
    if part.hl then
      for y = y0, y1 do
        mark(y, r.x, r.x + r.w, part.hl)
      end
    end
    if part.text_hl then
      local c = node.content
      for y = math.max(c.y, 0), math.min(c.y + c.h - 1, last) do
        mark(y, c.x, c.x + c.w, part.text_hl)
      end
    end
    if part.border_hl then
      local s = node.box.border.sides
      for y = y0, y1 do
        if (y == r.y and s.top == 1) or (y == r.y + r.h - 1 and s.bottom == 1) then
          mark(y, r.x, r.x + r.w, part.border_hl)
        else
          if s.left == 1 then
            mark(y, r.x, r.x + 1, part.border_hl)
          end
          if s.right == 1 then
            mark(y, r.x + r.w - 1, r.x + r.w, part.border_hl)
          end
        end
      end
    end
  end

  -- Hover state machine. Structural hovers flow through host.set_state +
  -- relayout (which re-enters us via on_flush — `syncing` breaks the cycle);
  -- the settle loop re-evaluates against the moved rects, capped because a
  -- structural hover can shift the layout out from under the cursor and
  -- oscillate (the documented hover-jank caveat).
  local hovered_fiber = nil
  local hovered_structural = false
  local syncing = false

  local function update()
    if syncing or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local node
    for _ = 1, 3 do
      node = node_under_cursor()
      local fiber = node and node.fiber
      if fiber == hovered_fiber then
        break
      end
      local dirty = false
      if hovered_fiber and hovered_structural then
        host.set_state(hovered_fiber, "hover", nil)
        dirty = true
      end
      hovered_fiber = fiber
      hovered_structural = node ~= nil and style.tier(hover_part(node)) == "structural"
      if hovered_structural then
        host.set_state(fiber, "hover", true)
        dirty = true
      end
      if not dirty then
        break
      end
      syncing = true
      host.relayout()
      syncing = false
    end
    paint(node)
  end

  -- `enter_subwins`: <CR> and clicks focus a subwindow under the cursor;
  -- <Space> passes false and only activates roles.
  local function activate(enter_subwins)
    if enter_subwins and subwins then
      local row, x = cursor_cell()
      if row and subwins.enter_at(row, x) then
        return
      end
    end
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

  local maps = { "<CR>", "<Space>" }
  vim.keymap.set("n", "<CR>", function()
    activate(true)
  end, { buffer = bufnr, nowait = true, desc = "fibrous: activate" })
  vim.keymap.set("n", "<Space>", function()
    activate(false)
  end, { buffer = bufnr, nowait = true, desc = "fibrous: activate" })
  if mouse.activate then
    maps[#maps + 1] = "<LeftRelease>"
    vim.keymap.set("n", "<LeftRelease>", function()
      activate(true)
    end, { buffer = bufnr, nowait = true, desc = "fibrous: activate (mouse)" })
  end

  -- Insert-entry keys: over a subwindow they focus its float and replay the
  -- key inside (native semantics at the translated cell); elsewhere they
  -- replay unmapped, which on the unmodifiable root is vim's own no-op/E21.
  if subwins then
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O" }) do
      maps[#maps + 1] = key
      vim.keymap.set("n", key, function()
        local row, x = cursor_cell()
        if row then
          subwins.enter_at(row, x)
        end
        -- "i": BEFORE anything still in the typeahead (a batched "ifoo" must
        -- replay as i,f,o,o); "n": noremap, so this map does not recurse.
        vim.api.nvim_feedkeys(key, "in", false)
      end, { buffer = bufnr, nowait = true, desc = "fibrous: edit subwindow" })
    end
  end
  local saved_mousemoveevent = nil
  if mouse.follow then
    saved_mousemoveevent = vim.o.mousemoveevent
    vim.o.mousemoveevent = true
    maps[#maps + 1] = "<MouseMove>"
    vim.keymap.set("n", "<MouseMove>", function()
      local mp = vim.fn.getmousepos()
      -- only within the root window: never yank the cursor OUT of a
      -- subwindow (or another window entirely) just because the pointer moved
      if mp.winid == root_winid then
        pcall(vim.api.nvim_win_set_cursor, root_winid, { mp.line, mp.column - 1 })
        update()
      end
    end, { buffer = bufnr, desc = "fibrous: hover (mouse)" })
  end

  return {
    update = update,
    teardown = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      if saved_mousemoveevent ~= nil then
        vim.o.mousemoveevent = saved_mousemoveevent
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
        for _, lhs in ipairs(maps) do
          pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
        end
      end
    end,
  }
end

return M
