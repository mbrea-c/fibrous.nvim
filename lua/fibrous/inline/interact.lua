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
--   tab        <Tab>/<S-Tab> cycle the cursor through the target's
--              interactive nodes (roles + text_inputs) in DOCUMENT order
--              (pre-order — a column's stops finish before the next column
--              starts), wrapping at the ends. Landing is just a cursor move:
--              hover repaints, activation stays on <CR>, and subwindows are
--              still entered explicitly, never by traversal. Cycling is per
--              flush target — inside a container, its own interact layer
--              cycles the container's stops.
--   mouse      Neovim's own mouse=nvi handling moves the cursor on click, so
--              hover already follows clicks with no code here. On top of that
--              (tracker task 10, `opts.mouse`):
--                activate (default true)   <LeftRelease> fires the same
--                  activate path as <CR>, except text fields are entered in
--                  INSERT mode (see subwin.lua's click_insert policy — a
--                  pointer user may have no keyboard).
--                  Release, not press: a drag lands in
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

-- The deepest node at cell (x, y) whose props satisfy `pred`. Later children
-- paint over earlier ones, so they are tried in reverse; a non-matching subtree
-- falls through to the closest matching ancestor. `pred` picks the marker —
-- `role` for hover/activation, `on_key[key]` for an app-declared component key.
---@param node table  a node annotated by layout.compute
---@param x integer
---@param y integer
---@param pred fun(props: table): any
---@return table|nil
local function hit(node, x, y, pred)
  local r = node.rect
  if not r or x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then
    return nil
  end
  local children = node.children or {}
  for i = #children, 1, -1 do
    local found = hit(children[i], x, y, pred)
    if found then
      return found
    end
  end
  if node.props and pred(node.props) then
    return node
  end
  return nil
end

local function has_role(props)
  return props.role
end

---@class InteractHandle
---@field update fun(propagate?: boolean)  re-evaluate hover at the current cursor (CursorMoved / post-flush); `propagate` forces driving hover into child containers (nil = only when this window is current)
---@field activate fun(enter_subwins: boolean, via_click?: boolean)  run activation at the current cursor (roles + subwindow entry); a parent delegates into this after focusing the layer
---@field clear_hover fun()  drop this layer's hover (and any it drives in nested containers)
---@field teardown fun()

---@class InlineMouseOpts
---@field activate? boolean  click (<LeftRelease>) activates; default true
---@field follow? boolean    focus-follows-mouse via <MouseMove>; default false

-- Attach cursor interaction to one of `host`'s flush targets, displayed in
-- `root_winid` (the mount's root float by default; a container's float when
-- the subwin manager recurses — then `target` is that container's).
---@param host InlineHost
---@param root_winid integer
---@param mouse? InlineMouseOpts|false  false disables all mouse maps
---@param subwins? SubwinManager  explicit-focus target for <CR>/click/insert keys
---@param target? FlushTarget  which target's tree/buffer to interact with; default the root
---@param keys? string[]  normal-mode keys routed to the on_key handler of the component under the cursor
---@return InteractHandle
function M.attach(host, root_winid, mouse, subwins, target, keys)
  if mouse == false then
    mouse = { activate = false, follow = false }
  else
    mouse = vim.tbl_extend("keep", mouse or {}, { activate = true, follow = false })
  end
  target = target or host.root_target
  local bufnr = target.bufnr
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
    if not target.tree then
      return nil
    end
    local row, x = cursor_cell()
    if not row then
      return nil
    end
    return hit(target.tree, x, row, has_role)
  end

  -- Fire a component's own handler for `key`: the nearest node under the cursor
  -- carrying `on_key[key]` is called with the cursor's column within its content
  -- (like on_press). Generic — a component says "run this when `key` is pressed
  -- while I'm hovered"; fibrous neither names nor interprets the action. Keyed off
  -- on_key, not `role`, so such a component draws no hover and doesn't collide
  -- with <CR>/<Space> activation.
  local function fire_key(key)
    if not target.tree then
      return
    end
    local row, x = cursor_cell()
    if not row then
      return
    end
    local node = hit(target.tree, x, row, function(props)
      return props.on_key and props.on_key[key]
    end)
    if node then
      local local_x
      local c = node.content
      if x and c then
        local_x = math.min(math.max(x - c.x, 0), math.max(c.w - 1, 0))
      end
      node.props.on_key[key](local_x)
    end
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

  -- Drop this layer's hover (and any it drives in nested containers). Used when
  -- this surface's cursor isn't the live pointer — an unfocused container the
  -- parent isn't pointing at, or a parent pointer that has left the container.
  local function clear_hover()
    if hovered_fiber and hovered_structural then
      host.set_state(hovered_fiber, "hover", nil)
      -- `syncing` guards re-entry: a relayout re-runs flush → update(), and a
      -- clear called mid-flush lets the ongoing flush do the repaint instead.
      if not syncing then
        syncing = true
        host.relayout()
        syncing = false
      end
    end
    hovered_fiber = nil
    hovered_structural = false
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
    end
    if subwins and subwins.clear_hover then
      subwins.clear_hover()
    end
  end

  -- Re-evaluate hover at this window's cursor and paint it. Hover only makes
  -- sense where the cursor is the LIVE pointer: this window is current, or a
  -- parent drove us here (`propagate`). Otherwise — an unfocused container's
  -- update() during a flush — the cursor is stale, so we show nothing (else a
  -- container would paint a phantom hover wherever its idle cursor happened to
  -- sit). `propagate`: true/false forces liveness (hover_at delegates true so a
  -- root-driven hover reaches nested containers); nil derives it from focus.
  ---@param propagate? boolean
  local function update(propagate)
    if syncing or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local live = propagate
    if live == nil then
      live = vim.api.nvim_win_is_valid(root_winid) and vim.api.nvim_get_current_win() == root_winid
    end
    if not live then
      clear_hover()
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

    if subwins and subwins.hover_at then
      local row, x = cursor_cell()
      if row then
        subwins.hover_at(row, x)
      end
    end
  end

  -- The target's Tab stops in document order: every role-carrying node plus
  -- text_input subwindow leaves (form fields are reachable by keyboard; a
  -- container leaf's children live in ANOTHER target's tree, so a container
  -- is not a stop here — its own interact layer cycles them).
  local function stops()
    local out = {}
    local function walk(node)
      if (node.props and node.props.role) or node.subwin == "text_input" then
        out[#out + 1] = node
      end
      for _, child in ipairs(node.children or {}) do
        walk(child)
      end
    end
    if target.tree then
      walk(target.tree)
    end
    return out
  end

  -- Move the cursor to the next (+1) / previous (-1) stop, wrapping. From a
  -- stop, strictly document-order cyclic; from an inert cell, the first stop
  -- spatially past the cursor in reading order (fall back to wrapping).
  local function cycle(dir)
    local list = stops()
    if #list == 0 then
      return
    end
    local row, x = cursor_cell()
    if not row then
      return
    end

    local current
    for i, node in ipairs(list) do
      local r = node.rect
      if x >= r.x and x < r.x + r.w and row >= r.y and row < r.y + r.h then
        current = i -- keep the last match: deeper in document order
      end
    end

    local idx
    if current then
      idx = (current + dir - 1) % #list + 1
    elseif dir == 1 then
      for i, node in ipairs(list) do
        local c = node.content
        if c.y > row or (c.y == row and c.x > x) then
          idx = i
          break
        end
      end
      idx = idx or 1
    else
      for i = #list, 1, -1 do
        local c = list[i].content
        if c.y < row or (c.y == row and c.x < x) then
          idx = i
          break
        end
      end
      idx = idx or #list
    end

    local c = list[idx].content
    local y = math.max(c.y, 0)
    local line = vim.api.nvim_buf_get_lines(bufnr, y, y + 1, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, root_winid, { y + 1, cell_to_byte(line, c.x) })
    update()
  end

  -- `enter_subwins`: <CR> and clicks act on a subwindow under the cursor;
  -- <Space> passes false and only activates roles. `via_click`: clicks enter
  -- text fields in INSERT mode (subwin.lua's click_insert policy) — a
  -- pointer user may have no keyboard; <CR> users have `i` right there.
  -- `activate_at` focuses the subwindow AND runs its own interaction once, so
  -- a button in a container is pressed in ONE <CR> (focus crosses in, the
  -- container's layer presses the role or hops into a nested subwindow) — no
  -- more "one <CR> to enter, one to act" at each level.
  local function activate(enter_subwins, via_click)
    local row, x = cursor_cell()
    if enter_subwins and subwins then
      if row and subwins.activate_at(row, x, via_click) then
        return
      end
    end
    local node = node_under_cursor()
    if not node then
      return
    end
    local props = node.props
    if props.role == "button" and props.on_press then
      -- the press column WITHIN the node's content box (display cells, 0-based),
      -- so a widget can act on WHERE it was pressed (e.g. ripple at the click).
      -- Older handlers that take no argument simply ignore it.
      local local_x
      local c = node.content
      if x and c then
        local_x = math.min(math.max(x - c.x, 0), math.max(c.w - 1, 0))
      end
      props.on_press(local_x)
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
  -- <Tab> shadows <C-i> (jumplist-forward) inside the canvas buffer — the
  -- usual trade for UI buffers.
  maps[#maps + 1] = "<Tab>"
  vim.keymap.set("n", "<Tab>", function()
    cycle(1)
  end, { buffer = bufnr, nowait = true, desc = "fibrous: next interactive" })
  maps[#maps + 1] = "<S-Tab>"
  vim.keymap.set("n", "<S-Tab>", function()
    cycle(-1)
  end, { buffer = bufnr, nowait = true, desc = "fibrous: previous interactive" })
  if mouse.activate then
    maps[#maps + 1] = "<LeftRelease>"
    vim.keymap.set("n", "<LeftRelease>", function()
      activate(true, true)
    end, { buffer = bufnr, nowait = true, desc = "fibrous: activate (mouse)" })
  end
  -- App-declared component keys: each is routed to the on_key handler of the
  -- component under the cursor (nothing fires if none there carries it).
  for _, key in ipairs(keys or {}) do
    maps[#maps + 1] = key
    vim.keymap.set("n", key, function()
      fire_key(key)
    end, { buffer = bufnr, nowait = true, desc = "fibrous: component key " .. key })
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
    -- Exposed so a parent's subwin manager can delegate activation into this
    -- (container) layer after focusing it — the recursive half of
    -- `subwins.activate_at`.
    activate = activate,
    -- Exposed so a parent's subwin manager can drop this layer's hover when its
    -- pointer leaves the container (the clear half of `subwins.hover_at`).
    clear_hover = clear_hover,
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
