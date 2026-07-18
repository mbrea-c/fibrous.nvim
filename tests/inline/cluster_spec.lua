-- Grapheme clusters in the cell pipeline. A combining character composed onto
-- a head char contributes 0 width inside a string, but a LONE combining char
-- measures 1 (nvim_strwidth) -- so per-CODEPOINT iteration with per-char
-- widths smeared composed text across cells. The shared cluster iterator in
-- width.lua (charclass == 2, memoized) fixes canvas painting, render cropping
-- and cell_to_byte -- the last one is what keeps the cursor/hit-map correct
-- over buffer lines full of image placeholder clusters.

local width = require("fibrous.inline.width")
local Canvas = require("fibrous.inline.canvas")
local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")

local eacute = "e\204\129" -- e + U+0301 combining acute (decomposed)

describe("width.clusters", function()
  it("attaches combining chars to their head char", function()
    local out = {}
    for cl in width.clusters(eacute .. "x" .. eacute) do
      out[#out + 1] = cl
    end
    assert.same({ eacute, "x", eacute }, out)
  end)

  it("plain ascii yields one cluster per char", function()
    local out = {}
    for cl in width.clusters("ab") do
      out[#out + 1] = cl
    end
    assert.same({ "a", "b" }, out)
  end)

  it("multiple diacritics stay on one head", function()
    local cluster = "e\204\129\204\130" -- e + acute + circumflex
    local out = {}
    for cl in width.clusters(cluster .. "z") do
      out[#out + 1] = cl
    end
    assert.same({ cluster, "z" }, out)
  end)

  it("a leading combining char is its own cluster", function()
    local out = {}
    for cl in width.clusters("\204\129a") do
      out[#out + 1] = cl
    end
    assert.same({ "\204\129", "a" }, out)
  end)

  it("precomposed and width-1 multibyte chars are NOT combining", function()
    -- charclass alone cannot decide this: é, α and U+10EEEE all report the
    -- word-char class (2), same as true combining marks. The behavioral test
    -- is composition: a combining char adds no width to a base char.
    assert.is_false(width.is_combining("\195\169")) -- é precomposed U+00E9
    assert.is_false(width.is_combining("\206\177")) -- α U+03B1
    assert.is_true(width.is_combining("\204\129")) -- U+0301 combining acute
  end)

  it("precomposed chars stay their own cluster", function()
    local out = {}
    for cl in width.clusters("x\195\169y") do
      out[#out + 1] = cl
    end
    assert.same({ "x", "\195\169", "y" }, out)
  end)

  it("image placeholder clusters do not merge with each other or a prefix", function()
    local kitty = require("fibrous.image.kitty")
    local a, b = kitty.cell(0, 0), kitty.cell(0, 1)
    local out = {}
    for cl in width.clusters("x" .. a .. b) do
      out[#out + 1] = cl
    end
    assert.same({ "x", a, b }, out)
  end)
end)

describe("width.cell_to_byte", function()
  it("steps whole clusters, not codepoints", function()
    local line = eacute .. "x"
    assert.equal(0, width.cell_to_byte(line, 0))
    assert.equal(3, width.cell_to_byte(line, 1)) -- past the whole cluster
    assert.equal(4, width.cell_to_byte(line, 2))
  end)

  it("ascii lines behave as before", function()
    assert.equal(0, width.cell_to_byte("abc", 0))
    assert.equal(2, width.cell_to_byte("abc", 2))
    assert.equal(3, width.cell_to_byte("abc", 9))
  end)

  it("wide chars still count two cells", function()
    local line = "漢x"
    assert.equal(3, width.cell_to_byte(line, 2))
    assert.equal(4, width.cell_to_byte(line, 3))
  end)

  it("addresses cells inside an image placeholder run", function()
    -- the run must NOT swallow its neighbors into one giant cluster: every
    -- placeholder is one cell, and interior cells resolve to real offsets
    -- (the subwin mark repair translates extmark cols through this — a
    -- mis-walk collapses image highlights, and with them the image)
    local kitty = require("fibrous.image.kitty")
    local line = "ab" .. kitty.cell(0, 0) .. kitty.cell(0, 1) .. "z"
    assert.equal(2, width.cell_to_byte(line, 2)) -- run start
    assert.equal(10, width.cell_to_byte(line, 3)) -- after one placeholder
    assert.equal(18, width.cell_to_byte(line, 4)) -- run end
    assert.equal(19, width.cell_to_byte(line, 5))
  end)
end)

describe("canvas cluster painting", function()
  it("a composed char occupies ONE cell and following text lands next to it", function()
    local c = Canvas.new(5, 1)
    c:text(0, 0, eacute .. "x")
    assert.same({ eacute .. "x   " }, c:lines())
  end)

  it("highlight spans stay byte-aligned over clusters", function()
    local c = Canvas.new(3, 1)
    c:text(0, 0, eacute .. "x", "T")
    assert.same({ { row = 0, start_col = 0, end_col = 4, hl = "T" } }, c:highlights())
  end)

  it("precomposed chars get their own cell instead of folding backwards", function()
    local c = Canvas.new(5, 1)
    c:text(0, 0, "x\195\169y")
    assert.same({ "x\195\169y  " }, c:lines())
  end)
end)

describe("render cropping over clusters", function()
  it("keeps clusters whole when cropping to the content box", function()
    local tree = { kind = "text", text = eacute .. "xy", props = { width = 2 } }
    layout.compute(tree, { width = 2 })
    local c = render.paint(tree, 2, 1)
    assert.same({ eacute .. "x" }, c:lines())
  end)
end)
