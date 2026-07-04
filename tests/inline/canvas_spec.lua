-- The cell-grid canvas (tracker "NEW UI HOST" task 2): render.lua paints the
-- laid-out tree onto it, the host flushes it as buffer lines + extmark
-- highlight spans. Cells hold UTF-8 chars; `lines()` joins rows and
-- `highlights()` reports BYTE-indexed spans (what nvim_buf_set_extmark wants),
-- merging adjacent same-hl cells.

local Canvas = require("fibrous.inline.canvas")

describe("inline.canvas", function()
  it("starts blank at the given size", function()
    local c = Canvas.new(5, 2)
    assert.same({ "     ", "     " }, c:lines())
    assert.same({}, c:highlights())
  end)

  it("text lands at (x, y) and out-of-bounds writes clip silently", function()
    local c = Canvas.new(5, 2)
    c:text(1, 0, "hi")
    c:text(3, 1, "long-tail") -- clips at the right edge
    c:text(-2, 1, "abc") -- clips at the left edge; the "c" survives
    c:text(0, 9, "nope") -- fully off-canvas row
    assert.same({ " hi  ", "c  lo" }, c:lines())
  end)

  it("highlight spans are byte-indexed and merge adjacent same-hl cells", function()
    local c = Canvas.new(6, 1)
    c:text(1, 0, "héllo", "Title") -- é = 2 bytes, 1 cell
    local hls = c:highlights()
    assert.same({ { row = 0, start_col = 1, end_col = 7, hl = "Title" } }, hls)
  end)

  it("different hls split into separate spans", function()
    local c = Canvas.new(6, 1)
    c:text(0, 0, "ab", "A")
    c:text(2, 0, "cd", "B")
    assert.same({
      { row = 0, start_col = 0, end_col = 2, hl = "A" },
      { row = 0, start_col = 2, end_col = 4, hl = "B" },
    }, c:highlights())
  end)

  it("hl_rect paints a background over a region, one span per row", function()
    local c = Canvas.new(4, 3)
    c:hl_rect({ x = 1, y = 0, w = 2, h = 2 }, "Cursor")
    assert.same({
      { row = 0, start_col = 1, end_col = 3, hl = "Cursor" },
      { row = 1, start_col = 1, end_col = 3, hl = "Cursor" },
    }, c:highlights())
  end)

  it("hl_rect keeps existing text and later text writes keep the rect hl when own hl is nil", function()
    local c = Canvas.new(4, 1)
    c:hl_rect({ x = 0, y = 0, w = 4, h = 1 }, "Bg")
    c:text(0, 0, "ok")
    assert.same({ "ok  " }, c:lines())
    assert.same({ { row = 0, start_col = 0, end_col = 4, hl = "Bg" } }, c:highlights())
  end)

  it("a double-width char occupies two cells and following text lands after it", function()
    local c = Canvas.new(6, 1)
    c:text(0, 0, "日x")
    assert.same({ "日x   " }, c:lines())
  end)

  it("a double-width char that would be cut at the edge becomes a space", function()
    local c = Canvas.new(3, 1)
    c:text(2, 0, "日")
    assert.same({ "   " }, c:lines())
  end)
end)

describe("inline.canvas grow", function()
  it("appends blank rows in place, keeping existing cells and spans", function()
    local c = Canvas.new(4, 2)
    c:text(0, 0, "abcd", "Title")
    c:text(0, 1, "ef")

    c:grow(4)

    assert.equal(4, c.h)
    assert.same({ "abcd", "ef  ", "    ", "    " }, c:lines())
    assert.same({ { row = 0, start_col = 0, end_col = 4, hl = "Title" } }, c:highlights())
    c:text(0, 3, "gh") -- the new rows are real, writable cells
    assert.equal("gh  ", c:line(4))
  end)
end)
