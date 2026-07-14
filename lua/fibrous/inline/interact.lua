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
-- Span-level hover overlay lives in its OWN namespace so it and the node-level
-- hover (ns_hover) clear independently — a text node with interactive spans is
-- not itself a role node, so the two paths never contend for the same cells.
local ns_span = vim.api.nvim_create_namespace("fibrous_inline_span_hover")

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

-- The deepest TEXT leaf (one carrying line_runs, so its spans are addressable)
-- at cell (x, y), or nil. Interactive spans live inside these.
local function text_node_at(node, x, y)
  local r = node.rect
  if not r or x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then
    return nil
  end
  local children = node.children or {}
  for i = #children, 1, -1 do
    local found = text_node_at(children[i], x, y)
    if found then
      return found
    end
  end
  if node.kind == "text" and node.line_runs then
    return node
  end
  return nil
end

-- The deepest KEYED node at cell (x, y): the innermost entry carrying a stable
-- `key` (host-stamped from the spec). Anchoring keys on this, not fiber identity,
-- since positional reconciliation reuses a fiber for whatever entry lands at its
-- index. Falls through to the closest keyed ancestor, like `hit`.
---@return table|nil
local function keyed_at(node, x, y)
  local r = node.rect
  if not r or x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then
    return nil
  end
  local children = node.children or {}
  for i = #children, 1, -1 do
    local found = keyed_at(children[i], x, y)
    if found then
      return found
    end
  end
  if node.key ~= nil then
    return node
  end
  return nil
end

-- The deepest node at cell (x, y), regardless of key — the fallback identity
-- when nothing under the cursor is keyed. A pure relayout (resize) runs no
-- reconciliation, so the fiber backref is stable and relocates the same content.
local function deepest_at(node, x, y)
  local r = node.rect
  if not r or x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h then
    return nil
  end
  local children = node.children or {}
  for i = #children, 1, -1 do
    local found = deepest_at(children[i], x, y)
    if found then
      return found
    end
  end
  return node
end

-- The node whose fiber backref is `fiber`, anywhere in the tree, or nil.
local function node_with_fiber(node, fiber)
  if node.fiber == fiber then
    return node
  end
  for _, child in ipairs(node.children or {}) do
    local found = node_with_fiber(child, fiber)
    if found then
      return found
    end
  end
  return nil
end

-- The node carrying `key` anywhere in the laid-out tree, or nil.
local function node_with_key(node, key)
  if node.key == key then
    return node
  end
  for _, child in ipairs(node.children or {}) do
    local found = node_with_key(child, key)
    if found then
      return found
    end
  end
  return nil
end

---@class InteractHandle
---@field update fun(propagate?: boolean)  re-evaluate hover at the current cursor (CursorMoved / post-flush); `propagate` forces driving hover into child containers (nil = only when this window is current)
---@field update_at fun(row: integer, x: integer)  re-evaluate hover at a parent-DRIVEN pointer (buffer row / display cell, 0-indexed) without touching this surface's real cursor
---@field reanchor fun(damage: any)  after a flush, put the cursor back on its anchored keyed entry (no-op when damage is false/nil or the surface is unfocused)
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
---@param anchor? boolean  keep the cursor on its keyed entry across relayout (default true; false opts out)
---@return InteractHandle
function M.attach(host, root_winid, mouse, subwins, target, keys, anchor)
  if mouse == false then
    mouse = { activate = false, follow = false }
  else
    mouse = vim.tbl_extend("keep", mouse or {}, { activate = true, follow = false })
  end
  target = target or host.root_target
  local anchor_enabled = anchor ~= false
  local bufnr = target.bufnr
  local group = vim.api.nvim_create_augroup("FibrousInlineInteract_" .. root_winid, { clear = true })

  -- A parent-DRIVEN pointer (buffer row, display cell), delegated here by the
  -- parent's subwin.hover_at when its cursor sits over this (container)
  -- surface. Consulted instead of the real cursor while this window is not
  -- current: writing the float's cursor to track the parent — the old nudge —
  -- invalidated the float and made the compositor repaint it WHOLE, once per
  -- root keystroke over the mirror and once per flush while streaming with the
  -- cursor parked on it (requests.md full-redraw bug). Cleared with the hover.
  ---@type { row: integer, x: integer }|nil
  local driven_cell = nil

  -- The root cursor as a buffer cell (row, x), both 0-indexed; nil when the
  -- root window is gone.
  local function cursor_cell()
    if not vim.api.nvim_win_is_valid(root_winid) then
      return nil
    end
    if driven_cell and vim.api.nvim_get_current_win() ~= root_winid then
      return driven_cell.row, driven_cell.x
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

  -- What the hover overlay currently shows: the hovered FIBER + its rect. The
  -- fiber is stable across a re-render (reconciliation reuses it) even when the
  -- built node is a fresh object, so this means "the overlay on the buffer is
  -- still correct" — the guard that keeps a parent-driven re-drive (hover_at on
  -- every animation frame) from tearing the overlay down and repainting it. When
  -- the content under it actually changes the buffer is re-spliced, which routes
  -- through clear_hover (resetting this) before the repaint.
  local shown_fiber, shown_rect = nil, nil
  local function rects_eq(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
  end

  -- Is our overlay still on the buffer at `rect`? A re-splice of those rows
  -- (the node re-rendered) deletes the extmarks, so "present" distinguishes an
  -- untouched overlay (skip the repaint) from one the buffer change wiped (must
  -- repaint) — without threading per-flush damage through every update() caller.
  local function overlay_present(rect)
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    local y0 = math.min(math.max(rect.y, 0), last)
    local y1 = math.min(math.max(rect.y + rect.h - 1, 0), last)
    local ex = vim.api.nvim_buf_get_extmarks(bufnr, ns_hover, { y0, 0 }, { y1, -1 }, { limit = 1 })
    return #ex > 0
  end

  -- Paint the hl-tier hover overlay for `node` (structural hovers were baked
  -- into the canvas by the relayout, so there is nothing left to overlay).
  local function paint(node)
    -- Idempotent: same fiber at the same rect, with its overlay still intact,
    -- is already correct — the guard that stops a parent-driven re-drive (every
    -- animation frame) from tearing down and repainting an unchanged hover.
    if
      node
      and shown_fiber ~= nil
      and node.fiber == shown_fiber
      and rects_eq(node.rect, shown_rect)
      and overlay_present(node.rect)
    then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
    if not node then
      shown_fiber, shown_rect = nil, nil
      return
    end
    local part = hover_part(node)
    if style.tier(part) == "structural" then
      -- baked into the canvas by the relayout; nothing to overlay or track
      shown_fiber, shown_rect = nil, nil
      return
    end
    shown_fiber = node.fiber
    shown_rect = { x = node.rect.x, y = node.rect.y, w = node.rect.w, h = node.rect.h }
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

  -- ── Interactive spans (links) ───────────────────────────────────────────
  -- A span carrying on_click/_hover is addressed at RUN granularity inside its
  -- text leaf. Everything a span can do is hl-only, so hover is a plain overlay
  -- in ns_span (no relayout), and click reuses the activate path.

  -- The run under the cursor, its text leaf, and the run's starting cell col.
  ---@return SpanRun|nil, table|nil, integer|nil
  local function run_under_cursor()
    if not target.tree then
      return nil
    end
    local row, x = cursor_cell()
    if not row then
      return nil
    end
    local node = text_node_at(target.tree, x, row)
    if not node then
      return nil
    end
    local content = node.content
    local runs = node.line_runs[row - content.y + 1]
    if not runs then
      return nil
    end
    local cx = content.x
    for _, run in ipairs(runs) do
      local w = str_width(run.text)
      if x >= cx and x < cx + w then
        return run, node, cx
      end
      cx = cx + w
    end
    return nil
  end

  -- Every cell range of the runs in `node` sharing logical span `id`, one entry
  -- per (wrapped) fragment: { y, x0, x1 }.
  local function span_rects(node, id)
    local out = {}
    local content = node.content
    for li, runs in ipairs(node.line_runs or {}) do
      local y = content.y + li - 1
      local cx = content.x
      for _, run in ipairs(runs) do
        local w = str_width(run.text)
        if run.id == id then
          out[#out + 1] = { y = y, x0 = cx, x1 = cx + w }
        end
        cx = cx + w
      end
    end
    return out
  end

  -- One span-hover extmark at cell range [x0, x1) of row y, above the node
  -- hover (4200) and the base spans (4096).
  local function mark_span(y, x0, x1, hl)
    local line = vim.api.nvim_buf_get_lines(bufnr, y, y + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns_span, y, cell_to_byte(line, x0), {
      end_col = cell_to_byte(line, x1),
      hl_group = hl,
      priority = 4300,
    })
  end

  -- What the span overlay currently shows: the text leaf's fiber + the span id.
  local span_shown = nil
  local function span_present()
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns_span, 0, -1, { limit = 1 }) > 0
  end

  -- Drop the span-hover overlay.
  local function clear_span_hover()
    if span_shown and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_span, 0, -1)
      span_shown = nil
    end
  end

  -- Paint the hover overlay for the interactive span under the cursor (all its
  -- wrapped runs), or clear it. Interactive = carries a hover group or a click;
  -- a span with only on_click gets the default FibrousHover cue.
  local function paint_span_hover()
    local run, node = run_under_cursor()
    local key = (run and run.id and (run.hover_hl or run.on_click)) and { fiber = node.fiber, id = run.id }
      or nil
    if key and span_shown and span_shown.fiber == key.fiber and span_shown.id == key.id and span_present() then
      return -- same span, overlay intact
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns_span, 0, -1)
    span_shown = nil
    if not key then
      return
    end
    local hl = run.hover_hl or "FibrousHover"
    for _, rect in ipairs(span_rects(node, run.id)) do
      mark_span(rect.y, rect.x0, rect.x1, hl)
    end
    span_shown = key
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
    driven_cell = nil
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
    -- Only touch the buffer when something is actually shown, so a repeated
    -- clear (an unfocused container's per-flush update) isn't a redraw each time.
    if shown_fiber and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_hover, 0, -1)
      shown_fiber, shown_rect = nil, nil
    end
    clear_span_hover()
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
      clear_span_hover()
      return
    end
    paint_span_hover()
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

  -- Drive hover from a PARENT's pointer at (row, x) — this surface's buffer
  -- coords — without focusing the surface or touching its real cursor. The
  -- parent's subwin.hover_at delegates here; deeper containers are reached
  -- through update's own subwins.hover_at recursion, which reads the driven
  -- cell back out of cursor_cell.
  ---@param row integer  buffer row (0-indexed)
  ---@param x integer  display cell (0-indexed)
  local function update_at(row, x)
    driven_cell = { row = row, x = x }
    update(true)
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
    -- An interactive span under the cursor takes precedence (deepest wins): its
    -- text leaf is not a role node, so node_under_cursor would miss it anyway.
    local run, _, rx0 = run_under_cursor()
    if run and run.on_click then
      run.on_click(x and rx0 and math.max(x - rx0, 0) or nil)
      return
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

  -- ── Cursor anchoring across relayout ────────────────────────────────────
  -- The vim cursor holds an ABSOLUTE line; a count-changing relayout (a width
  -- resize rewraps everything, a mid-list insert shifts the tail) re-splices the
  -- span it sits in and leaves it on a row that now holds different content. We
  -- track what the cursor is on as the user moves, then after each relayout put
  -- the cursor back on it — holding its screen row so the view doesn't jump.
  -- Identity, best first: a `key` (survives INSERT/REORDER, since positional
  -- reconciliation reuses a fiber for whatever entry lands at its index); else
  -- the node's fiber (stable across a pure relayout like a resize, which runs no
  -- reconciliation — this is what pins keyless UIs).
  ---@type { key: any, fiber: any, offset: integer, screen_row: integer }|nil
  local anchor_state = nil

  -- Is this surface the live pointer (its window current)? Only then is the
  -- cursor the user's, so only then do we capture/restore against it — an
  -- unfocused transcript is owned by the app's own follow-to-bottom.
  local function pointer_live()
    return vim.api.nvim_win_is_valid(root_winid) and vim.api.nvim_get_current_win() == root_winid
  end

  -- Remember what the reader is looking at and where it sits on screen. Not
  -- gated to focus: an unfocused surface is captured too (on WinScrolled), so a
  -- later relayout can hold its view. The REFERENCE is the cursor's entry when
  -- the cursor is on-screen — the user's place; a focused window's cursor always
  -- is, and an unfocused one is while a scroll dragged it along or the app parked
  -- it in view (follow-to-bottom sits it on the last line). When the cursor is
  -- off-screen (parked out of view, then scrolled away) it no longer says what
  -- the reader sees, so anchor the TOP of the viewport instead.
  local function capture_anchor()
    if not anchor_enabled or not target.tree then
      return
    end
    local row, x = cursor_cell()
    if not row then
      return
    end
    local topline = vim.api.nvim_win_call(root_winid, function()
      return vim.fn.winsaveview().topline
    end)
    local top_row = topline - 1 -- 0-indexed row at the top of the viewport
    local height = vim.api.nvim_win_get_height(root_winid)
    local cursor_onscreen = row >= top_row and row < top_row + height
    local ref_row = cursor_onscreen and row or top_row
    local ref_x = cursor_onscreen and (x or 0) or 0
    -- prefer the deepest KEYED entry (reorder-stable); fall back to the deepest
    -- node's fiber (resize-stable) so keyless UIs pin too
    local node = keyed_at(target.tree, ref_x, ref_row) or deepest_at(target.tree, ref_x, ref_row)
    if not node then
      anchor_state = nil
      return
    end
    anchor_state = {
      key = node.key, -- nil for the fiber fallback
      fiber = node.fiber,
      offset = ref_row - node.rect.y, -- rows into the entry
      screen_row = ref_row - top_row, -- rows below the top of the viewport
      cursor = cursor_onscreen, -- the reference was the cursor (vs the top row)
    }
  end

  -- After a relayout that rewrote the buffer, move the cursor back onto its
  -- anchored entry (and hold its screen row). `damage` follows take_damage:
  -- `false` = nothing changed (skip); a range table = a splice; `nil` = a FULL
  -- repaint ("all" — what a container gets on a resize rewrap), which we MUST
  -- re-anchor for. So skip only on the explicit false, not on nil.
  local function reanchor(damage)
    if not anchor_enabled or not anchor_state or damage == false then
      return
    end
    if not target.tree then
      return
    end
    -- relocate by key (reorder-stable) or, for a keyless anchor, by fiber
    local node
    if anchor_state.key ~= nil then
      node = node_with_key(target.tree, anchor_state.key)
    else
      node = node_with_fiber(target.tree, anchor_state.fiber)
    end
    if not node then
      return -- the entry is gone (e.g. collapsed away): leave the view be
    end
    local r = node.rect
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    local new_row = math.min(math.max(r.y + math.min(anchor_state.offset, math.max(r.h - 1, 0)), 0), last)
    local want_topline = math.max(new_row - anchor_state.screen_row + 1, 1)

    -- Focused, and the anchor is the cursor's own entry: the cursor is the
    -- user's, so pin it back onto its entry AND hold its screen row.
    if pointer_live() and anchor_state.cursor then
      local line = vim.api.nvim_buf_get_lines(bufnr, new_row, new_row + 1, false)[1] or ""
      local cur_col = vim.api.nvim_win_get_cursor(root_winid)[2]
      local want_lnum = new_row + 1
      local want_col = math.min(cur_col, #line)
      vim.api.nvim_win_call(root_winid, function()
        -- Idempotent: a flush that didn't move the anchored entry (an animating
        -- sibling repainting every frame while the root is the live pointer) leaves
        -- the view already correct. winrestview is a WRITE — it invalidates the
        -- window and repaints the WHOLE float — so calling it every frame with the
        -- same values turns the anchor into a full-float redraw per frame (the
        -- ssh+tmux flicker-frenzy). Only restore when the view actually differs.
        local v = vim.fn.winsaveview()
        if v.topline == want_topline and v.lnum == want_lnum and v.col == want_col and (v.leftcol or 0) == 0 then
          return
        end
        vim.fn.winrestview({
          topline = want_topline,
          lnum = want_lnum,
          col = want_col,
          leftcol = 0,
        })
      end)
      return
    end

    -- Otherwise the surface is UNFOCUSED (or its cursor was off-screen): hold the
    -- VIEW only, so the reader's content stays put across the relayout, and leave
    -- the cursor to the app's own follow-to-bottom (which owns an unfocused
    -- cursor — moving it here would fight follow). Only when there is actually
    -- something scrolled: a surface whose content fits the window has no scroll
    -- position to keep, and writing topline would only fight its pin-to-top.
    if vim.api.nvim_buf_line_count(bufnr) <= vim.api.nvim_win_get_height(root_winid) then
      return
    end
    vim.api.nvim_win_call(root_winid, function()
      local v = vim.fn.winsaveview() -- same idempotency guard, topline only
      if v.topline == want_topline and (v.leftcol or 0) == 0 then
        return
      end
      vim.fn.winrestview({ topline = want_topline, leftcol = 0 })
    end)
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      capture_anchor()
      -- A real cursor move in THIS buffer means the cursor is live here, so
      -- force hover liveness (the bare autocmd used to pass its event table,
      -- which `update` read as a truthy `propagate`).
      update(true)
    end,
  })

  -- Scrolling (wheel, <C-e>/<C-y>, zz…) moves the view without necessarily
  -- moving the cursor. Re-capture so the anchor tracks WHERE THE USER IS LOOKING
  -- NOW — otherwise the next damage flush would restore the pre-scroll screen row
  -- and snap the view back, fighting every scroll in a frequently-rendering app.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    pattern = tostring(root_winid),
    callback = capture_anchor,
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
    -- Entering visual mode over a subwindow focuses it and starts the selection
    -- INSIDE the float, so you select real sub-buffer text (requests.md). Away
    -- from a subwindow enter_at is a no-op and the key replays natively — visual
    -- mode in the parent canvas, as before.
    for _, key in ipairs({ "v", "V", "<C-v>" }) do
      maps[#maps + 1] = key
      vim.keymap.set("n", key, function()
        local row, x = cursor_cell()
        if row then
          subwins.enter_at(row, x)
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "in", false)
      end, { buffer = bufnr, nowait = true, desc = "fibrous: visual-select subwindow" })
    end
    -- Edit operators over an UNFOCUSED editable subwindow focus it and finish the
    -- edit inside the float (requests.md: dd/cb/ce…). The key replays after focus
    -- so operator + motion (dd, ce, cw, 3dd) all land in the float; over a
    -- non-editable float or bare canvas the key is native (a no-op on the
    -- unmodifiable root). Only editable subwindows are entered — a container is
    -- not a text-edit buffer. Yank is left out: the canvas mirror is real text,
    -- so y already copies it without a focus hop.
    for _, key in ipairs({ "d", "c", "s", "x", "r", "~", ">", "<", "=", "J", "D", "C", "S", "X", "p", "P" }) do
      maps[#maps + 1] = key
      vim.keymap.set("n", key, function()
        local row, x = cursor_cell()
        if row then
          subwins.enter_editable_at(row, x)
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "in", false)
      end, { buffer = bufnr, nowait = true, desc = "fibrous: edit subwindow (operator)" })
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
    -- Exposed so a parent's subwin manager can drive hover into this
    -- (container) layer at its translated pointer — the paint half of
    -- `subwins.hover_at` — without a cursor write into the float.
    update_at = update_at,
    -- Called by the mount / subwin manager after a flush: restore the cursor to
    -- its anchored entry once the buffer has been re-spliced.
    reanchor = reanchor,
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
