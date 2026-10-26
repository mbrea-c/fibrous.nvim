-- Logical document provenance for rendered selections and overlay projections.
-- IDs/data belong to the application. Source offsets are zero-based UTF-8 bytes.
local Width = require("fibrous.inline.width")
local Clip = require("fibrous.inline.clip")
local M = {}
local buffers, listeners = {}, {}

local function notify(buf)
  if #listeners == 0 then return end
  for _, fn in ipairs(vim.list_extend({}, listeners)) do pcall(fn, buf) end
end
function M.subscribe(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, value in ipairs(listeners) do if value == fn then table.remove(listeners, i); break end end
  end
end

function M.update(buf, tree)
  local target = buffers[buf]
  if not target then target = {}; buffers[buf] = target end
  target.tree, target.source = tree, nil
  notify(buf)
end
function M.raw(buf, source)
  buffers[buf] = { source = source }
  notify(buf)
end
function M.clear(buf)
  buffers[buf] = nil
  notify(buf)
end
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("FibrousSources", { clear = true }),
  callback = function(ev) M.clear(ev.buf) end,
})

-- Enumerate only real, fully visible text clusters, not synthetic borders/padding.
local function clusters(buf, tree, emit, fallback, unmapped, query)
  local function walk(node, owner)
    local content = node.content
    owner = node.props and node.props.source_entry or owner
    if node.props and node.props.source_entry and node.rect and fallback then
      fallback(node.props.source_entry, Clip.visible(node))
    end
    if node.subwin then return end
    if emit and content and node.line_runs then
      for li, runs in ipairs(node.line_runs) do
        local x, row = content.x, content.y + li - 1
        if not query or not query.first_row or row >= query.first_row and row <= query.last_row then
          local line -- Read only when a requested, fully visible cluster needs checking.
          for _, run in ipairs(runs) do
            if query and query.id and (not run.source or run.source.id ~= query.id) then
              x = x + Width.str(run.text)
            else
              local byte, positions = 1, run.source_positions
              for ch in Width.clusters(run.text) do
                local cells = Width.char(ch)
                local first = positions and positions[byte]
                local last = positions and positions[byte + #ch - 1]
                local wanted = run.source or unmapped and owner
                if query and query.id then
                  wanted = type(first) == "number" and type(last) == "number"
                    and first < query.finish and last + 1 > query.start
                end
                if wanted then
                  local visible = Clip.visible(node, { x = x, y = row, w = cells, h = 1 })
                  if visible.w == cells and visible.h == 1 then
                    if not line then line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "" end
                    local col, ending = Width.cell_to_byte(line, x), Width.cell_to_byte(line, x + cells)
                    if line:sub(col + 1, ending) == ch then
                      if run.source and type(first) == "number" and type(last) == "number" then
                        emit(run.source, first, last + 1, row, col, ending, ch)
                      elseif unmapped and owner and ch:find("%S") then
                        unmapped(owner, row, col, ending)
                      end
                    end
                  end
                end
                x, byte = x + cells, byte + #ch
              end
            end
          end
        end
      end
    end
    for _, child in ipairs(node.children or {}) do walk(child, owner) end
  end
  if tree then walk(tree) end
end

local function raw_clusters(buf, source, emit)
  local offset = source.offset or 0
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local byte = 0
    for ch in Width.clusters(line) do
      emit(source, offset + byte, offset + byte + #ch, row - 1, byte, byte + #ch, ch)
      byte = byte + #ch
    end
    offset = offset + #line + 1
  end
end

function M.owns(buf) return buffers[buf] ~= nil end

-- Buffer selection ranges are 1-based inclusive, like Neovim visual marks.
function M.resolve(buf, range)
  local target = buffers[buf]
  if not target or not vim.api.nvim_buf_is_valid(buf) then return {} end
  local out, fallback, precise, incomplete = {}, {}, {}, {}
  local first, last = range.lnum - 1, (range.end_lnum or range.lnum) - 1
  local function selected(row, col, ending)
    if row < first or row > last then return false end
    local start = row == first and (range.col or 1) - 1 or 0
    local finish = row == last and range.end_col or math.huge
    return col < (finish or math.huge) and ending > start
  end
  local function emit(source, start, finish, row, col, ending, ch)
    if not selected(row, col, ending) then return end
    local key = source.data and source.data.entry_id or source.id
    precise[key] = true
    local previous = out[#out]
    if previous and previous.source.id == source.id and start >= previous.start_byte then
      previous.end_byte = math.max(previous.end_byte, finish)
      previous.quote = previous.quote .. (previous._row ~= row and "\n" or "") .. ch
      previous._row = row
    else
      out[#out + 1] = { source = source, start_byte = start, end_byte = finish,
        quote = ch, precision = "exact", _row = row }
    end
  end
  local function quote(box)
    local lines = {}
    for row = math.max(first, box.y), math.min(last, box.y + box.h - 1) do
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local col, ending = Width.cell_to_byte(line, box.x), Width.cell_to_byte(line, box.x + box.w)
      if row == first then col = math.max(col, (range.col or 1) - 1) end
      if row == last then ending = math.min(ending, range.end_col or ending) end
      lines[#lines + 1] = line:sub(col + 1, ending):gsub("%s+$", "")
    end
    return table.concat(lines, "\n")
  end
  if target.source then raw_clusters(buf, target.source, emit)
  else
    clusters(buf, target.tree, emit, function(source, box)
      if box and box.w > 0 and box.h > 0 and box.y <= last and box.y + box.h > first then
        fallback[#fallback + 1] = { source = source, start_byte = 0, end_byte = 0,
          quote = quote(box), precision = "entry", _row = box.y }
      end
    end, function(source, row, col, ending)
      if selected(row, col, ending) then
        incomplete[source.data and source.data.entry_id or source.id] = true
      end
    end, { first_row = first, last_row = last })
  end
  local mapped = {}
  for _, value in ipairs(out) do
    local key = value.source.data and value.source.data.entry_id or value.source.id
    if not incomplete[key] then mapped[#mapped + 1] = value end
  end
  out = mapped
  for _, value in ipairs(fallback) do
    local key = value.source.data and value.source.data.entry_id or value.source.id
    if incomplete[key] or not precise[key] then
      out[#out + 1] = value; precise[key], incomplete[key] = true, nil
    end
  end
  table.sort(out, function(a, b) return a._row < b._row end)
  for _, value in ipairs(out) do value._row = nil end
  return out
end

-- Project logical bytes into current buffer coordinates (row/columns 0-based,
-- end_col exclusive). Missing/unmounted content simply has no locations.
function M.project(id, start, finish)
  local out = {}
  for buf, target in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      local function emit(source, a, b, row, col, ending)
        if source.id ~= id or a >= finish or b <= start then return end
        local last = out[#out]
        if last and last.bufnr == buf and last.row == row and last.end_col == col then last.end_col = ending
        else out[#out + 1] = { bufnr = buf, row = row, start_col = col, end_col = ending } end
      end
      if target.source then
        if target.source.id == id then raw_clusters(buf, target.source, emit) end
      else clusters(buf, target.tree, emit, nil, nil, { id = id, start = start, finish = finish }) end
    else buffers[buf] = nil end
  end
  table.sort(out, function(a, b)
    if a.bufnr == b.bufnr then return a.row == b.row and a.start_col < b.start_col or a.row < b.row end
    return a.bufnr < b.bufnr
  end)
  return out
end

function M.entry_locations(entry_id)
  local out = {}
  for buf, target in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and target.tree then
      clusters(buf, target.tree, nil, function(source, box)
        if source.data and source.data.entry_id == entry_id and box and box.w > 0 and box.h > 0 then
          local line = vim.api.nvim_buf_get_lines(buf, box.y, box.y + 1, false)[1] or ""
          out[#out + 1] = { bufnr = buf, row = box.y, start_col = Width.cell_to_byte(line, box.x),
            end_col = Width.cell_to_byte(line, box.x + box.w) }
        end
      end)
    end
  end
  return out
end

return M
