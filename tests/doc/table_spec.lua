-- Table rendering (fibrous.doc.table): an ast.table to a col of fixed-width
-- cell rows. No new layout primitive — column widths are the max cell content
-- width per column (userland), applied as fixed cell widths so columns align;
-- alignment is flex justify within the cell. Inline content (bold, links)
-- renders through the shared inline path, so it survives inside cells.

local ast = require("fibrous.doc.ast")
local dtable = require("fibrous.doc.table")
local ui = require("fibrous.inline.components")
local mount = require("fibrous.inline.mount")

local function sample()
  return ast.table({
    align = { "left", "right" },
    header = { { ast.text("Name") }, { ast.text("Qty") } },
    rows = {
      { { ast.text("apple") }, { ast.text("3") } },
      { { ast.text("pear") }, { ast.text("12") } },
    },
  })
end

describe("fibrous.doc.table", function()
  it("renders as a col: header row, separator, then body rows", function()
    local v = dtable.render(sample(), {})
    assert.equal(ui.col, v.comp)
    -- header + separator + 2 body rows
    assert.equal(4, #v.children)
  end)

  it("aligns the columns (every rendered row is the same width)", function()
    local handle = mount.floating(function()
      return dtable.render(sample(), {})
    end, {}, { width = 40, height = 8 })
    local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)

    local nonblank, divcols = {}, {}
    for _, l in ipairs(lines) do
      if l:match("%S") then
        nonblank[#nonblank + 1] = l
        local b = l:find("│")
        if b then
          divcols[vim.fn.strdisplaywidth(l:sub(1, b - 1))] = true
        end
      end
    end
    assert.equal(4, #nonblank) -- header, separator, 2 rows
    -- the column divider lands at the SAME display column in every row → aligned
    assert.equal(1, vim.tbl_count(divcols), "column divider aligned across rows")

    local txt = table.concat(lines, "\n")
    assert.truthy(txt:find("Name", 1, true))
    assert.truthy(txt:find("Qty", 1, true))
    assert.truthy(txt:find("│", 1, true), "column divider present")
    assert.truthy(txt:find("─", 1, true), "header separator present")

    handle.unmount()
  end)
end)
