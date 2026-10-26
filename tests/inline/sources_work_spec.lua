local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local Sources = require("fibrous.sources")

describe("bounded source query work", function()
  local app, text, starts
  before_each(function()
    local lines = {}
    starts = {}
    local at = 0
    for i = 1, 80 do
      starts[i] = at
      lines[i] = ("row %03d selected words and some filler"):format(i)
      at = at + #lines[i] + 1
    end
    text = table.concat(lines, "\n")
    app = mount.floating(function()
      local children = {}
      for i, line in ipairs(lines) do
        children[i] = { comp = ui.label, props = { text = line,
          source = { id = "large", text = text, offset = starts[i], data = { entry_id = "large-entry" } } } }
      end
      return { comp = ui.col, props = { source_entry = {
        id = "whole", text = text, data = { entry_id = "large-entry" } } }, children = children }
    end, {}, { width = 60, height = 10, mode = "scroll" })
  end)
  after_each(function() if app then app.unmount() end end)

  local function reads(fn)
    local original, count = vim.api.nvim_buf_get_lines, 0
    vim.api.nvim_buf_get_lines = function(...)
      local lines = original(...)
      count = count + #lines
      return lines
    end
    local ok, value = pcall(fn)
    vim.api.nvim_buf_get_lines = original
    if not ok then error(value, 0) end
    return count, value
  end

  it("does not read unrelated rendered rows when projecting a small source range", function()
    local start = starts[40] + 8
    local count, found = reads(function() return Sources.project("large", start, start + 8) end)
    assert.equal(1, #found)
    assert.equal(39, found[1].row)
    assert.equal("selected", vim.api.nvim_buf_get_text(app.bufnr, 39, found[1].start_col, 39, found[1].end_col, {})[1])
    assert.is_true(count <= 2, ("small projection read %d rows"):format(count))
  end)

  it("does not read unselected rows when capturing a small selection", function()
    local count, found = reads(function()
      return Sources.resolve(app.bufnr, { lnum = 40, end_lnum = 40, col = 9, end_col = 16 })
    end)
    assert.equal(1, #found)
    assert.equal("selected", found[1].quote)
    assert.is_true(count <= 3, ("small selection read %d rows"):format(count))
  end)

  it("locates an entry using its box without reading all of its text", function()
    local count, found = reads(function() return Sources.entry_locations("large-entry") end)
    assert.equal(1, #found)
    assert.equal(0, found[1].row)
    assert.is_true(count <= 2, ("entry lookup read %d rows"):format(count))
  end)

  it("keeps nonmonotonic maps and composed characters addressable", function()
    local other = mount.floating(function()
      return { comp = ui.label, props = { text = "αβé界", source = {
        id = "reordered", map = { 20, 21, 0, 1, 3, 4, 5, 10, 11, 12 } } } }
    end, {}, { width = 20, height = 3 })
    local ok, err = pcall(function()
      local found = Sources.project("reordered", 20, 22)
      assert.equal(1, #found)
      assert.equal("α", vim.api.nvim_buf_get_text(other.bufnr, found[1].row,
        found[1].start_col, found[1].row, found[1].end_col, {})[1])
      local combined = Sources.project("reordered", 3, 6)
      assert.equal("é", vim.api.nvim_buf_get_text(other.bufnr, combined[1].row,
        combined[1].start_col, combined[1].row, combined[1].end_col, {})[1])
    end)
    other.unmount()
    if not ok then error(err, 0) end
  end)
end)
