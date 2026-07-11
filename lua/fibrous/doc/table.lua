-- Table rendering for the document renderer. A table needs one thing col/row
-- do not give directly: column widths SHARED across rows. We compute those in
-- userland (the max cell content width per column) and apply them as fixed cell
-- widths, so columns line up; per-column alignment is flex justify inside the
-- cell. No new layout primitive, and inline content (bold, links) renders
-- through the shared inline path, so it keeps working inside cells.
--
-- v1 is intrinsic-width: columns size to content and a too-wide table clips or
-- scrolls in its container. Responsive tables (fit the container, wrap cells)
-- would use the width-aware `fill` node and are a follow-up.

local ui = require("fibrous.inline.components")
local render = require("fibrous.doc.render")
local spans = require("fibrous.inline.spans")
local width = require("fibrous.inline.width")

local M = {}

local DIVIDER = " │ " -- between cells in a data row (3 cells)

local JUSTIFY = { left = "start", center = "center", right = "end" }

-- Display width of a cell's rendered inline content.
local function cell_width(inline_nodes, opts)
  local text = spans.flatten(render.inline(inline_nodes, opts))
  return width.str(text)
end

-- A fixed-width cell node: the inline content, aligned within `w` cells.
local function cell(inline_nodes, w, align, opts)
  return {
    comp = ui.row,
    props = { width = w, justify = JUSTIFY[align] or "start" },
    children = { { comp = ui.text, props = { text = render.inline(inline_nodes, opts), wrap = false } } },
  }
end

-- A data row: cells joined by the vertical divider.
local function data_row(cells, widths, align, opts)
  local children = {}
  for c = 1, #widths do
    if c > 1 then
      children[#children + 1] = { comp = ui.label, props = { text = DIVIDER, style = { text_hl = "NonText" } } }
    end
    children[#children + 1] = cell(cells[c] or {}, widths[c], align[c], opts)
  end
  return { comp = ui.row, props = {}, children = children }
end

-- Render an ast.table node to a fibrous vnode (a col of rows).
---@param node table  { type="table", align, header, rows }
---@param opts table
---@return table vnode
function M.render(node, opts)
  local align = node.align or {}
  local ncols = #node.header
  for _, row in ipairs(node.rows) do
    ncols = math.max(ncols, #row)
  end

  -- column widths: max content width across header + every row
  local widths = {}
  for c = 1, ncols do
    local w = cell_width(node.header[c] or {}, opts)
    for _, row in ipairs(node.rows) do
      w = math.max(w, cell_width(row[c] or {}, opts))
    end
    widths[c] = math.max(w, 1)
  end

  -- header separator: a run of ─ per column, joined by ─┼─ so junctions line up
  -- with the data rows' " │ " dividers (both 3 cells wide).
  local seg = {}
  for c = 1, ncols do
    seg[c] = ("─"):rep(widths[c])
  end
  local separator = {
    comp = ui.label,
    props = { text = table.concat(seg, "─┼─"), style = { text_hl = "NonText" } },
  }

  local header_cells = {}
  for c = 1, ncols do
    header_cells[c] = node.header[c] or {}
  end

  local children = { data_row(header_cells, widths, align, opts), separator }
  for _, row in ipairs(node.rows) do
    children[#children + 1] = data_row(row, widths, align, opts)
  end
  return { comp = ui.col, props = {}, children = children }
end

return M
