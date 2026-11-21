-- Retain a native Markdown layout between Lua component commits in scroll mode.
local ffi = require("ffi")
local width = require("fibrous.inline.width")
local sources = require("fibrous.sources")
local M = {}

-- Packed records are native-endian uint32 values from the versioned module.
---@param value any
---@return integer
local function uint(value)
  return assert(tonumber(value))
end

local function registry()
  local list, ids = {}, {}
  return list,
    function(obj)
      if not obj then
        return 0
      end
      if not ids[obj] then
        list[#list + 1] = obj
        ids[obj] = #list
      end
      return ids[obj]
    end
end

local function compile(node, state)
  -- Keep the host fiber, role, key and style of the real node. Publish native
  -- geometry through a separate view so the Lua host can reuse its own layout
  -- and paint caches when a subsequent commit changes the document.
  local view = setmetatable({ children = {}, line_runs = false }, { __index = node })
  local slot = #state.views + 1
  state.views[slot] = view
  local props = node.props or {}
  assert(not node.subwin and not node.fill, "unsupported Markdown leaf")
  assert(not props.source_entry, "whole-entry provenance requires the Lua renderer")
  assert(
    not props.height and not props.min_height and not props.max_height and not props.min_width and not props.max_width,
    "unsupported layout constraint"
  )
  assert(not props.width or node.kind == "row", "unsupported fixed width")
  assert(not props._markdown or not (props.width or props.grow or props.align_self), "constrained Markdown root")
  local style = node.style_resolved or {}
  local function zero(s)
    return not s or (s.left == 0 and s.right == 0 and s.top == 0 and s.bottom == 0)
  end
  assert(not style.hl and zero(style.margin), "unsupported background or margin")
  local border = style.border
  local sides = border and border.sides
  local quote = node.kind == "col"
    and sides
    and sides.left == 1
    and sides.right == 0
    and sides.top == 0
    and sides.bottom == 0
    and border.chars.left == "│"
    and not border.title
    and style.padding.left == 1
    and style.padding.right == 0
    and style.padding.top == 0
    and style.padding.bottom == 0
  assert(quote or (zero(sides) and zero(style.padding)), "unsupported Markdown box")
  assert(node.kind == "text" or not style.text_hl, "unsupported container foreground")
  local entry = { kind = node.kind, slot = slot, intrinsic = node.size.w, grow = (props.grow or 0) > 0 }
  if node.kind == "text" then
    local text, ranges = node._text, node._ranges or {}
    assert(props.wrap ~= "char" and not text:find("[%z\1-\9\11-\31]"), "unsupported control or wrapping mode")
    local hit_ids = {}
    for _, range in ipairs(ranges) do
      if range.id then
        local id = #state.hits + 1
        state.hits[id] = { view = view, range = range }
        hit_ids[range] = id
      end
    end
    view.has_hits = next(hit_ids) ~= nil
    local glyphs = ffi.new("uint32_t[?]", math.max(1, #text * 5))
    local offsets = ffi.new("int32_t[?]", math.max(1, #text))
    local g, at, ri = 0, 1, 1
    for ch in width.clusters(text) do
      while ranges[ri] and ranges[ri].e <= at do
        ri = ri + 1
      end
      local r = ranges[ri]
      if r and r.s > at then
        r = nil
      end
      assert(not r or r.e >= at + #ch, "cluster crosses a style boundary")
      ---@type table|nil
      local s = r and r.source
      glyphs[g] = #ch
      glyphs[g + 1] = ch == "\n" and 1 or width.char(ch)
      assert(glyphs[g + 1] == 1 or glyphs[g + 1] == 2, "unsupported display width")
      glyphs[g + 2] = state.style_id(r and r.hl or (node.style_resolved or {}).text_hl)
      glyphs[g + 3] = state.source_id(s)
      glyphs[g + 4] = hit_ids[r] or 0
      for j = at, at + #ch - 1 do
        local p
        if s and r then
          local index = assert(r.source_base) + j - r.s
          p = s.map and s.map[index] or not s.map and index - 1
        end
        offsets[j - 1] = s and type(p) == "number" and (s.offset or 0) + p or -1
      end
      g, at = g + 5, at + #ch
    end
    entry.text, entry.wrap = text, props.wrap == true
    entry.glyphs = ffi.string(glyphs, g * 4)
    entry.positions = ffi.string(offsets, #text * 4)
    return entry, view
  end

  assert(node.kind == "row" or node.kind == "col", "unsupported Markdown container")
  entry.gap = props.gap or 0
  if node.kind == "row" then
    assert(not props.align or props.align == "start", "unsupported row alignment")
    entry.justify = props.justify or "start"
    assert(entry.justify == "start" or entry.justify == "center" or entry.justify == "end")
  else
    assert(not props.justify or props.justify == "start", "unsupported column justification")
    assert(not props.align or props.align == "center", "unsupported Markdown column alignment")
    entry.center = props.align == "center"
  end
  if quote then
    local hl = style.border_hl
    if hl == nil then
      hl = border.hl
    end
    if hl == nil then
      hl = "FibrousBorder"
    end
    entry.border = state.style_id(hl)
  end
  entry.children = {}
  for i, child in ipairs(node.children or {}) do
    entry.children[i], view.children[i] = compile(child, state)
  end
  return entry, view
end

-- Rendered offsets have already been computed in Rust. Expand compact spans
-- into the existing sources module's line_runs format only if a caller asks.
local function source_tree(lines, packed, objects)
  return setmetatable({ content = { x = 0, y = 0 } }, {
    __index = function(tree, k)
      if k ~= "line_runs" then
        return
      end
      local maps = ffi.cast("const uint32_t*", packed)
      local rows, cursor = {}, 0
      for row, line in ipairs(lines) do
        local runs, col = {}, 0
        while cursor < #packed / 4 and maps[cursor] == row - 1 do
          local a, b, id, offset =
            uint(maps[cursor + 1]), uint(maps[cursor + 2]), uint(maps[cursor + 3]), uint(maps[cursor + 4])
          if col < a then
            runs[#runs + 1] = { text = line:sub(col + 1, a) }
          end
          local positions = {}
          for i = 1, b - a do
            positions[i] = offset + i - 1
          end
          runs[#runs + 1] = { text = line:sub(a + 1, b), source = objects[id], source_positions = positions }
          col, cursor = b, cursor + 5
        end
        rows[row] = runs
      end
      tree.line_runs = rows
      return rows
    end,
  })
end

local function retained(tree, lib)
  local styles, style_id = registry()
  local objects, source_id = registry()
  local state = {
    styles = styles,
    objects = objects,
    style_id = style_id,
    source_id = source_id,
    hits = {},
    views = {},
    original = tree,
  }
  local entry, view = compile(tree, state)
  state.doc, state.view = lib.compile(entry), view
  return state
end

-- The native paint supplies cell bounds for hit-testing and byte bounds for
-- slicing the actual rendered text. A link split by wrapping keeps its Lua
-- callback and leaf-local span ID across every visible fragment.
local function update_view(state, lines, boxes, fragments)
  local data = ffi.cast("const uint32_t*", boxes)
  for i = 0, #boxes / 4 - 1, 6 do
    local view = state.views[uint(data[i])]
    local x, y = uint(data[i + 1]), uint(data[i + 2])
    local w, h, inset = uint(data[i + 3]), uint(data[i + 4]), uint(data[i + 5])
    view.rect = { x = x, y = y, w = w, h = h }
    view.content = inset == 0 and view.rect or { x = x + inset, y = y, w = math.max(w - inset, 0), h = h }
    if view.has_hits then
      local rows = {}
      for j = 1, h do
        rows[j] = {}
      end
      view.line_runs = rows
    end
  end
  data = ffi.cast("const uint32_t*", fragments)
  for i = 0, #fragments / 4 - 1, 6 do
    local row, x, right = uint(data[i]), uint(data[i + 1]), uint(data[i + 2])
    local first, last = uint(data[i + 3]), uint(data[i + 4])
    local hit = state.hits[uint(data[i + 5])]
    local view, range = hit.view, hit.range
    local runs = view.line_runs[row - view.content.y + 1]
    local gap = x - (runs.right or view.content.x)
    if gap > 0 then
      runs[#runs + 1] = { text = (" "):rep(gap) }
    end
    runs[#runs + 1] = {
      text = lines[row + 1]:sub(first + 1, last),
      id = range.id,
      role = range.role,
      on_click = range.on_click,
      hl = range.hl,
      hover_hl = range.hover_hl,
    }
    runs.right = right
  end
end

function M.attach(host, get_size, on_flush, lib, eligible)
  local target = host.root_target
  local state = retained(host.tree, lib)
  local prev, prior_width = host.canvas_lines, host.tree.rect.w
  state.doc:resize(prior_width)
  local native_frame = false
  local commit, lua_relayout, set_state = host.commit, host.relayout, host.set_state
  local structural_change = false

  local function release_frame()
    if native_frame then
      -- Reconcile the next Lua paint against the actual visible frame. Only
      -- take this snapshot at the transition back to a component commit.
      local rows = {}
      for i = 1, #prev do
        rows[i] = {}
      end
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, host.ns, 0, -1, { details = true })) do
        local r, d = rows[mark[2] + 1], mark[4]
        if r and d and d.hl_group then
          r[#r + 1] = { row = mark[2], start_col = mark[3], end_col = d.end_col, hl = d.hl_group }
        end
      end
      target.prev_lines, target.prev_hl_rows, target.canvas = prev, rows, nil
      host.tree, target.tree = state.original, state.original
      native_frame = false
    end
    state = nil
    host.markdown_backend = "lua"
  end

  host.commit = function(...)
    release_frame()
    structural_change = false
    return commit(...)
  end
  host.set_state = function(...)
    structural_change = true
    return set_state(...)
  end
  local teardown = host.teardown
  host.teardown = function(...)
    state, prev = nil, nil
    return teardown(...)
  end
  host.relayout = function()
    if structural_change then
      release_frame()
      structural_change = false
      return lua_relayout()
    end
    if not host.tree or not vim.api.nvim_buf_is_valid(host.bufnr) then
      return
    end
    local size = get_size()
    if
      size.height
      or size.width < 1
      or size.width > 16384
      or (eligible and not eligible(state and state.original or host.tree))
    then
      release_frame()
      target.tree = nil -- force the Lua clean-frame guard to repaint the real buffer
      return lua_relayout()
    end
    local fresh = state == nil
    if fresh then
      prev, prior_width = host.canvas_lines, host.tree.rect.w
    end
    if size.width == prior_width then
      if on_flush then
        on_flush(nil)
      end
      return
    end
    if fresh then
      local ok, result = pcall(retained, host.tree, lib)
      if not ok then
        host.markdown_fallback = tostring(result)
        return lua_relayout()
      end
      state = result
    end
    local ok, from, old_end, changed, marks, maps, boxes, hits = pcall(state.doc.resize, state.doc, size.width)
    if not ok then
      host.markdown_fallback = tostring(from)
      release_frame()
      target.tree = nil
      return lua_relayout()
    end
    -- After an edit a newly compiled document returns the entire new frame.
    if fresh then
      old_end = #prev
    end
    local buf = host.bufnr
    local damage
    local lines = {}
    for i = 1, from do
      lines[i] = prev[i]
    end
    for i, line in ipairs(changed) do
      lines[from + i] = line
    end
    for i = old_end + 1, #prev do
      lines[#lines + 1] = prev[i]
    end
    if old_end > from or #changed > 0 then
      local pinned = {}
      if #lines == #prev then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          local p = vim.api.nvim_win_get_cursor(win)
          if p[1] > from and p[1] <= old_end then
            local line = vim.api.nvim_buf_get_lines(buf, p[1] - 1, p[1], false)[1]
            pinned[#pinned + 1] = { win, p[1], width.str(line:sub(1, p[2])) }
          end
        end
      end
      vim.api.nvim_buf_clear_namespace(buf, host.ns, from, old_end)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, from, old_end, false, changed)
      vim.bo[buf].modifiable = false
      for _, p in ipairs(pinned) do
        local line = vim.api.nvim_buf_get_lines(buf, p[2] - 1, p[2], false)[1]
        local col = width.cell_to_byte(line, p[3])
        if col ~= vim.api.nvim_win_get_cursor(p[1])[2] then
          vim.api.nvim_win_set_cursor(p[1], { p[2], col })
        end
      end
      local records = ffi.cast("const uint32_t*", marks)
      for i = 0, #marks / 4 - 1, 4 do
        vim.api.nvim_buf_set_extmark(
          buf,
          host.ns,
          uint(records[i]),
          uint(records[i + 1]),
          { end_col = uint(records[i + 2]), hl_group = state.styles[uint(records[i + 3])] }
        )
      end
      damage = { top = from, bot = from + #changed - 1 }
    end
    host.canvas_lines, host.root_target.canvas_lines = lines, lines
    update_view(state, lines, boxes, hits)
    host.tree, target.tree = state.view, state.view
    prev, prior_width, native_frame = lines, size.width, true
    host.markdown_backend = "rust"
    sources.update(buf, source_tree(lines, maps, state.objects))
    if on_flush then
      on_flush(damage)
    end
  end
end
return M
