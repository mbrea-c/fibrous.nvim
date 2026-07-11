-- Pure-Lua LaTeX math rendering (fibrous.doc.math). A shared TeX parser feeds
-- two renderers: `single` (a flat Unicode line, for inline $...$) and `stack`
-- (a 2D box layout, for display $$...$$). No treesitter, no binary, so it runs
-- everywhere fibrous does. Unknown commands degrade to their name/verbatim.

local m = require("fibrous.doc.math")

describe("fibrous.doc.math single-line", function()
  it("substitutes common symbols", function()
    assert.equal("α + β", m.single("\\alpha + \\beta"))
    assert.equal("a ≤ b", m.single("a \\leq b"))
    assert.equal("2 × 3", m.single("2 \\times 3"))
    assert.equal("∑ x", m.single("\\sum x"))
  end)

  it("renders unicode super/subscripts (superscript before subscript)", function()
    assert.equal("x²", m.single("x^2"))
    assert.equal("xᵢ", m.single("x_i"))
    assert.equal("x¹⁰", m.single("x^{10}"))
    assert.equal("aₙ", m.single("a_n"))
    assert.equal("x²ᵢ", m.single("x^2_i"))
  end)

  it("falls back to ^(..)/_(..) when no unicode script char exists", function()
    assert.equal("x^(β)", m.single("x^{\\beta}"))
    assert.equal("a_(θ)", m.single("a_{\\theta}"))
  end)

  it("renders fractions and roots inline", function()
    assert.equal("1/2", m.single("\\frac{1}{2}"))
    assert.equal("(a+b)/2", m.single("\\frac{a+b}{2}"))
    assert.equal("√x", m.single("\\sqrt{x}"))
    assert.equal("√(a+b)", m.single("\\sqrt{a+b}"))
  end)

  it("degrades unknown commands to their name", function()
    assert.equal("foo", m.single("\\foo"))
  end)

  it("renders \\quad and \\qquad as wide spaces", function()
    -- 4 and 8 spaces from the command, plus the literal space that terminates it
    assert.equal("a" .. string.rep(" ", 4) .. " b", m.single("a\\quad b"))
    assert.equal("a" .. string.rep(" ", 8) .. " b", m.single("a\\qquad b"))
  end)

  it("renders \\text{...} as upright literal text, keeping spaces", function()
    assert.equal("if x", m.single("\\text{if }x"))
  end)

  it("maps \\mathbf and \\mathit through the math alphanumeric blocks", function()
    assert.equal("𝐱", m.single("\\mathbf{x}"))
    assert.equal("𝐀𝐁", m.single("\\mathbf{AB}"))
    assert.equal("𝟎", m.single("\\mathbf{0}"))
    assert.equal("𝑥", m.single("\\mathit{x}"))
    assert.equal("ℎ", m.single("\\mathit{h}")) -- the italic-h hole uses U+210E
  end)

  it("places accents as combining marks inline", function()
    assert.equal("x\204\130", m.single("\\hat{x}")) -- x + U+0302 combining circumflex
    assert.equal("x\204\135", m.single("\\dot{x}")) -- x + U+0307 combining dot above
  end)

  it("wraps content in \\left \\right fences inline", function()
    assert.equal("(a+b)", m.single("\\left(a+b\\right)"))
    assert.equal("|x|", m.single("\\left|x\\right|"))
    assert.equal("[y]", m.single("\\left[y\\right]"))
  end)
end)

describe("fibrous.doc.math stacked (display)", function()
  it("stacks a simple fraction", function()
    assert.same({ "a", "─", "b" }, m.stack("\\frac{a}{b}"))
  end)

  it("centers a fraction over its wider part", function()
    assert.same({ "a+b", "───", " c " }, m.stack("\\frac{a+b}{c}"))
  end)

  it("keeps inline atoms on the fraction's axis row", function()
    local lines = m.stack("x = \\frac{a}{b}")
    assert.equal(3, #lines)
    assert.truthy(lines[2]:find("x = ", 1, true), "inline text on the axis row")
    assert.truthy(lines[2]:find("─", 1, true), "bar on the axis row")
  end)

  it("renders a square root with an overline", function()
    local lines = m.stack("\\sqrt{x}")
    assert.equal(2, #lines)
    assert.truthy(lines[1]:find("_", 1, true), "vinculum (underscore) on the row above")
    assert.truthy(lines[2]:find("√x", 1, true))
  end)

  it("nests fractions", function()
    -- \frac{1}{a/b}: denominator is itself a fraction (3 rows) => 5 rows total
    local lines = m.stack("\\frac{1}{\\frac{a}{b}}")
    assert.equal(5, #lines)
  end)

  it("grows a radical over a tall body", function()
    local lines = m.stack("\\sqrt{\\frac{a}{b}}")
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("╱", 1, true), "diagonal radical stroke")
    assert.truthy(joined:find("╲", 1, true), "radical check vertex")
  end)

  it("stacks a big operator's SMALL limits above and below", function()
    local lines = m.stack("\\sum_{k=1}^{n} k")
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("∑", 1, true), "1-line summand uses the plain ∑")
    -- limits render SMALL (unicode super/subscript), upper above lower
    local up, lo
    for i, l in ipairs(lines) do
      if l:find("ⁿ", 1, true) and not up then
        up = i
      end
      if l:find("ₖ", 1, true) then -- ₖ₌₁ (small subscript)
        lo = i
      end
    end
    assert.is_true(up ~= nil and lo ~= nil and up < lo, "small upper limit above small lower limit")
  end)

  it("sizes the operator glyph to the summand height", function()
    -- 2-line summand: the two-halves sigma
    assert.truthy(table.concat(m.stack("\\sum_{k=1}^{n} \\sqrt{x}"), "\n"):find("⎲", 1, true))
    -- 3+-line summand (a fraction): the scalable box-drawing sigma
    local box = table.concat(m.stack("\\sum_{k=1}^{n} \\frac{1}{k^2}"), "\n")
    assert.truthy(box:find("╱", 1, true) and box:find("╲", 1, true), "box-drawing sigma for a tall summand")
    assert.truthy(box:find("▔", 1, true), "edge-block bar (no diagonal gap)")
  end)

  it("treats LaTeX spacing commands as spaces (not literals)", function()
    assert.equal("f dx", m.single("f\\,dx"))
  end)

  it("applies \\mathbf to atoms inside a display fraction", function()
    assert.same({ "𝐚", "─", "b" }, m.stack("\\frac{\\mathbf{a}}{b}"))
  end)

  it("stacks an accent glyph over the base", function()
    assert.same({ "^", "x" }, m.stack("\\hat{x}"))
  end)

  it("raises a superscript on a tall group to its top row (not the centre)", function()
    local lines = m.stack("\\left(\\frac{a}{b}\\right)^2")
    assert.equal(3, #lines)
    assert.truthy(lines[1]:find("²", 1, true), "exponent on the top row")
    assert.falsy(lines[2]:find("²", 1, true), "not on the centre row")
  end)

  it("drops a subscript on a tall group to its bottom row", function()
    local lines = m.stack("\\left(\\frac{a}{b}\\right)_i")
    assert.truthy(lines[#lines]:find("ᵢ", 1, true), "subscript on the bottom row")
    assert.falsy(lines[2]:find("ᵢ", 1, true), "not on the centre row")
  end)

  it("sizes \\left \\right fences to the body height", function()
    local lines = m.stack("\\left(\\frac{a}{b}\\right)")
    assert.equal(3, #lines)
    assert.truthy(lines[1]:find("⎛", 1, true), "tall left paren top")
    assert.truthy(lines[2]:find("⎜", 1, true), "left paren extension")
    assert.truthy(lines[3]:find("⎝", 1, true), "left paren bottom")
    assert.truthy(lines[1]:find("⎞", 1, true), "tall right paren top")
    assert.truthy(lines[3]:find("⎠", 1, true), "right paren bottom")
  end)
end)
