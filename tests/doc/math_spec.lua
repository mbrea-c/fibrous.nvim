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

  it("supports \\mid and the \\not overlay", function()
    assert.equal("a ∣ b", m.single("a \\mid b"))
    assert.equal("=\204\184", m.single("\\not=")) -- = + U+0338 combining long solidus
    assert.equal("∈\204\184", m.single("\\not\\in")) -- overlays the next symbol too
  end)

  it("maps \\mathbb and \\mathcal, including the Letterlike-block holes", function()
    assert.equal("𝔸", m.single("\\mathbb{A}")) -- U+1D538 main block
    assert.equal("ℝ", m.single("\\mathbb{R}")) -- U+211D hole
    assert.equal("𝒜", m.single("\\mathcal{A}")) -- U+1D49C main block
    assert.equal("ℒ", m.single("\\mathcal{L}")) -- U+2112 hole
  end)

  it("overlines each char with a combining bar inline", function()
    assert.equal("A\204\133B\204\133", m.single("\\overline{AB}")) -- each char + U+0305
  end)

  it("wraps content in \\left \\right fences inline", function()
    assert.equal("(a+b)", m.single("\\left(a+b\\right)"))
    assert.equal("|x|", m.single("\\left|x\\right|"))
    assert.equal("[y]", m.single("\\left[y\\right]"))
  end)

  it("does not truncate multi-letter command names to their first letter", function()
    -- regression: a 2-char sym text (e.g. an unknown \\ab) was mis-proxied as its
    -- first letter only, because the variable-proxy guard tested byte length
    assert.equal("ab", m.single("\\ab"))
    -- and such a name is upright, not italicised as a one-letter variable
    assert.same({ { text = "ab", var = false } }, m.single_spans("\\ab"))
    -- a genuine single-letter variable still proxies (italic run)
    assert.same({ { text = "x", var = true } }, m.single_spans("x"))
  end)

  it("renders an nth root with a small index before the radical", function()
    assert.equal("³√x", m.single("\\sqrt[3]{x}"))
    assert.equal("ⁿ√(a+b)", m.single("\\sqrt[n]{a+b}"))
    assert.equal("√x", m.single("\\sqrt{x}")) -- no index unchanged
  end)

  it("linearises \\binom as the C(n, k) coefficient notation inline", function()
    assert.equal("C(n, k)", m.single("\\binom{n}{k}"))
    assert.equal("C(a+b, 2)", m.single("\\binom{a+b}{2}"))
  end)

  it("renders consecutive apostrophes as prime marks", function()
    assert.equal("x′", m.single("x'"))
    assert.equal("x″", m.single("x''"))
    assert.equal("x‴", m.single("x'''"))
    assert.equal("f′(x)", m.single("f'(x)"))
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

  it("draws \\overline as a bar hugging the content in display", function()
    -- ▁ (lower eighth block) sits at the bottom of the row above, so the bar
    -- rides just over the content rather than floating high
    assert.same({ "▁▁▁", "x+y" }, m.stack("\\overline{x+y}"))
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

  it("draws an nth-root index above the radical gutter", function()
    local lines = m.stack("\\sqrt[3]{x}")
    assert.truthy(lines[1]:find("³", 1, true), "small index on the top row")
    assert.truthy(lines[#lines]:find("√x", 1, true), "radical and body on the base row")
  end)

  it("stacks \\binom as num over den inside sized parens (no bar)", function()
    assert.same({ "⎛n⎞", "⎝k⎠" }, m.stack("\\binom{n}{k}"))
  end)
end)

describe("fibrous.doc.math expanded symbols and fonts", function()
  it("adds common logic, set and lattice relations", function()
    assert.equal("a ∧ b", m.single("a \\wedge b"))
    assert.equal("a ∨ b", m.single("a \\vee b"))
    assert.equal("a ≺ b", m.single("a \\prec b"))
    assert.equal("a ≻ b", m.single("a \\succ b"))
    assert.equal("a ⊑ b", m.single("a \\sqsubseteq b"))
    assert.equal("A ⊊ B", m.single("A \\subsetneq B"))
    assert.equal("⊤", m.single("\\top"))
    assert.equal("⊥", m.single("\\bot"))
    assert.equal("Γ ⊢ x", m.single("\\Gamma \\vdash x"))
    assert.equal("a ⊨ b", m.single("a \\models b"))
  end)

  it("adds Letterlike symbols and misc glyphs", function()
    assert.equal("ℵ", m.single("\\aleph"))
    assert.equal("ℜ", m.single("\\Re"))
    assert.equal("ℑ", m.single("\\Im"))
    assert.equal("∴", m.single("\\therefore"))
    assert.equal("∵", m.single("\\because"))
    assert.equal("†", m.single("\\dagger"))
    assert.equal("a ⊙ b", m.single("a \\odot b"))
  end)

  it("adds vertical, long and hooked arrows", function()
    assert.equal("a ↑ b", m.single("a \\uparrow b"))
    assert.equal("a ↓ b", m.single("a \\downarrow b"))
    assert.equal("x ⟶ y", m.single("x \\longrightarrow y"))
    assert.equal("p ⟹ q", m.single("p \\implies q"))
    assert.equal("a ↪ b", m.single("a \\hookrightarrow b"))
    assert.equal("A ← B", m.single("A \\gets B"))
  end)

  it("maps \\mathfrak (with Letterlike holes), \\mathsf and \\mathtt", function()
    assert.equal("𝔤", m.single("\\mathfrak{g}"))
    assert.equal("ℜ", m.single("\\mathfrak{R}")) -- Fraktur R hole = U+211C
    assert.equal("𝔞𝔟", m.single("\\mathfrak{ab}"))
    assert.equal("𝖷", m.single("\\mathsf{X}"))
    assert.equal("𝚔", m.single("\\mathtt{k}"))
  end)

  it("treats \\dfrac, \\tfrac and \\cfrac as \\frac", function()
    assert.equal("1/2", m.single("\\tfrac{1}{2}"))
    assert.same({ "a", "─", "b" }, m.stack("\\dfrac{a}{b}"))
  end)

  it("renders \\operatorname{...} as an upright multi-letter operator", function()
    assert.equal("argmax", m.single("\\operatorname{argmax}"))
    assert.same({ { text = "argmax", var = false } }, m.single_spans("\\operatorname{argmax}"))
  end)

  it("adds big operators that take limits", function()
    assert.equal("⨁", m.single("\\bigoplus"))
    assert.equal("⨂", m.single("\\bigotimes"))
    assert.equal("∐", m.single("\\coprod"))
    -- and they stack limits above/below in display, like \\sum
    local lines = m.stack("\\bigoplus_{i} a_i")
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("⨁", 1, true), "operator glyph present")
    assert.is_true(#lines >= 2, "a limit stacked onto its own row")
  end)
end)

describe("fibrous.doc.math named operators, wide accents, braces", function()
  it("keeps \\lim limits inline in single-line mode", function()
    assert.equal("lim_(x → 0) f", m.single("\\lim_{x \\to 0} f"))
  end)

  it("stacks \\lim (and \\max, \\sup) limits below in display", function()
    local lines = m.stack("\\lim_{x \\to 0} f")
    assert.is_true(#lines >= 2, "operator and its limit on separate rows")
    assert.truthy(lines[1]:find("lim", 1, true), "operator name on top")
    assert.truthy(lines[2]:find("x → 0", 1, true), "limit stacked below")
    assert.truthy(m.stack("\\max_{k} a_k")[2]:find("ₖ", 1, true), "\\max also stacks a small limit below")
  end)

  it("renders \\bmod and \\pmod", function()
    assert.equal("a mod b", m.single("a \\bmod b"))
    assert.equal("a (mod b)", m.single("a \\pmod{b}"))
  end)

  it("renders wide accents: a spanning arrow in display, combining inline", function()
    -- the stem is an em dash (U+2014), not box-drawing "─" (U+2500): in Iosevka
    -- the em dash meets the arrowhead's baseline, the box rule sits too high
    assert.same({ "—→", "AB" }, m.stack("\\overrightarrow{AB}"))
    assert.same({ "←—", "AB" }, m.stack("\\overleftarrow{AB}"))
    -- inline: the combining mark trails EVERY char (U+20D7 = "\226\131\151")
    assert.equal("A\226\131\151B\226\131\151", m.single("\\overrightarrow{AB}"))
    assert.equal("x\204\130y\204\130", m.single("\\widehat{xy}")) -- U+0302 per char
  end)

  it("draws \\overbrace and \\underbrace with an optional label", function()
    local over = m.stack("\\overbrace{a+b}^{n}")
    assert.equal("a+b", over[#over], "content on the bottom row")
    assert.truthy(over[1]:find("n", 1, true), "label above the brace")
    assert.truthy(table.concat(over, "\n"):find("⏞", 1, true), "top brace glyph")
    local under = m.stack("\\underbrace{x}_{k}")
    assert.equal("x", under[1], "content on the top row")
    assert.truthy(table.concat(under, "\n"):find("⏟", 1, true), "bottom brace glyph")
  end)

  it("renders \\overset, \\underset and \\stackrel", function()
    assert.equal("bᵃ", m.single("\\overset{a}{b}"))
    assert.equal("bₐ", m.single("\\underset{a}{b}"))
    assert.equal("bᵃ", m.single("\\stackrel{a}{b}"))
    assert.same({ "a", "b" }, m.stack("\\overset{a}{b}"))
    assert.same({ "b", "a" }, m.stack("\\underset{a}{b}"))
  end)
end)

describe("fibrous.doc.math environments", function()
  it("renders a pmatrix as a grid inside sized parens (display)", function()
    local lines = m.stack("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
    assert.equal(2, #lines)
    assert.truthy(lines[1]:find("⎛", 1, true), "tall left paren top")
    assert.truthy(lines[1]:find("a", 1, true) and lines[1]:find("b", 1, true), "first row cells")
    assert.truthy(lines[2]:find("c", 1, true) and lines[2]:find("d", 1, true), "second row cells")
    assert.truthy(lines[2]:find("⎠", 1, true), "right paren bottom")
  end)

  it("flattens a matrix inline with , between cells and ; between rows", function()
    assert.equal("(a, b; c, d)", m.single("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"))
  end)

  it("uses the right delimiters per environment", function()
    assert.equal("[a, b]", m.single("\\begin{bmatrix} a & b \\end{bmatrix}"))
    assert.equal("|a, b|", m.single("\\begin{vmatrix} a & b \\end{vmatrix}"))
    assert.truthy(m.stack("\\begin{bmatrix} a \\\\ b \\end{bmatrix}")[1]:find("⎡", 1, true), "bracket top")
  end)

  it("grows determinant and norm bars as connecting box-drawing lines", function()
    -- a tall bar must be the connecting │ (U+2502), not the gappy ASCII pipe, so
    -- the determinant reads as one continuous rule down the side
    local det = m.stack("\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}")
    assert.truthy(det[1]:find("│", 1, true), "box-drawing bar on the top row")
    assert.truthy(det[2]:find("│", 1, true), "and the bottom row")
    assert.falsy(det[1]:find("|", 1, true), "no ASCII pipe in the tall form")
    assert.truthy(table.concat(m.stack("\\left| \\frac{a}{b} \\right|"), "\n"):find("│", 1, true), "\\left|…\\right| too")
    -- the norm uses the double box line ║
    assert.truthy(m.stack("\\begin{Vmatrix} a \\\\ b \\end{Vmatrix}")[1]:find("║", 1, true), "double bar for a norm")
    -- a single bar stays a plain pipe (matches the surrounding text)
    assert.equal("|x|", m.single("\\left|x\\right|"))
  end)

  it("renders cases with a left brace and left-aligned rows", function()
    local lines = m.stack("\\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}")
    assert.equal(2, #lines)
    assert.truthy(lines[1]:find("⎧", 1, true), "left brace top")
    assert.truthy(lines[1]:find("1", 1, true) and lines[1]:find("x > 0", 1, true), "first case")
    assert.truthy(lines[2]:find("0", 1, true) and lines[2]:find("x ≤ 0", 1, true), "second case")
  end)

  it("aligns an aligned environment at the & column", function()
    local lines = m.stack("\\begin{aligned} x &= a + b \\\\ y &= c \\end{aligned}")
    assert.equal(2, #lines)
    local e1 = lines[1]:find("=", 1, true)
    local e2 = lines[2]:find("=", 1, true)
    assert.is_true(e1 ~= nil and e1 == e2, "the = signs line up across rows")
  end)

  it("handles a fraction cell (a tall matrix row)", function()
    local lines = m.stack("\\begin{pmatrix} \\frac{a}{b} & c \\end{pmatrix}")
    assert.equal(3, #lines) -- fraction is 3 rows tall, parens grow to match
    assert.truthy(table.concat(lines, "\n"):find("─", 1, true), "fraction bar present")
  end)
end)

describe("fibrous.doc.math nested and composite structures", function()
  it("parenthesises a nested fraction so the linear form is unambiguous", function()
    assert.equal("(a/b)/c", m.single("\\frac{\\frac{a}{b}}{c}"))
    assert.equal("1/(a/b)", m.single("\\frac{1}{\\frac{a}{b}}"))
    assert.equal("a/(b + c/d)", m.single("\\frac{a}{b + \\frac{c}{d}}"))
    assert.equal("√(a/b)", m.single("\\sqrt{\\frac{a}{b}}"))
    -- a root or sum operand needs no parens (already unambiguous)
    assert.equal("√a/√b", m.single("\\frac{\\sqrt{a}}{\\sqrt{b}}"))
  end)

  it("stacks a fraction nested inside a fraction (numerator and denominator)", function()
    assert.same({ "a", "─", "b", "─", "c" }, m.stack("\\frac{\\frac{a}{b}}{c}"))
    assert.same({ "1", "─", "a", "─", "b" }, m.stack("\\frac{1}{\\frac{a}{b}}"))
  end)

  it("puts an integral inside a fraction numerator, growing the bar to fit", function()
    local lines = m.stack("\\frac{\\int_0^1 f\\,dx}{2}")
    assert.equal(7, #lines)
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("⌠", 1, true), "tall integral sign in the numerator")
    assert.truthy(lines[#lines]:find("2", 1, true), "denominator on the bottom row")
    assert.equal("(∫¹₀ f dx)/2", m.single("\\frac{\\int_0^1 f\\,dx}{2}"))
  end)

  it("nests square roots, growing the radical", function()
    assert.equal("√(1 + √(1 + x))", m.single("\\sqrt{1 + \\sqrt{1 + x}}"))
    assert.truthy(table.concat(m.stack("\\sqrt{1 + \\sqrt{1 + x}}"), "\n"):find("╱", 1, true), "growing radical")
  end)

  it("sizes a big operator to a fractional summand", function()
    local joined = table.concat(m.stack("\\sum_{i=1}^{n} \\frac{x_i}{2}"), "\n")
    assert.truthy(joined:find("╱", 1, true) and joined:find("╲", 1, true), "box-drawing sigma for a 3-row summand")
    assert.truthy(joined:find("─", 1, true), "the summand's own fraction bar")
  end)

  it("keeps a fraction exponent readable inline", function()
    assert.equal("x^(a/b)", m.single("x^{\\frac{a}{b}}"))
    assert.equal("e^(-x²/2)", m.single("e^{-\\frac{x^2}{2}}"))
  end)

  it("lays out a matrix of tall cells (fraction, root, sum, integral)", function()
    local lines = m.stack("\\begin{pmatrix} \\frac{a}{b} & \\sqrt{c} \\\\ \\sum_{i} x_i & \\int f \\end{pmatrix}")
    assert.equal(6, #lines)
    assert.truthy(lines[1]:find("⎛", 1, true) and lines[#lines]:find("⎠", 1, true), "parens grow to the whole grid")
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("─", 1, true), "fraction bar in a cell")
    assert.truthy(joined:find("∑", 1, true), "sum in a cell")
  end)

  it("raises an exponent off a tall parenthesised group", function()
    local lines = m.stack("\\left(1 + \\frac{1}{n}\\right)^n")
    assert.equal(3, #lines)
    assert.truthy(lines[1]:find("ⁿ", 1, true), "exponent on the top row")
    assert.falsy(lines[2]:find("ⁿ", 1, true), "not on the centre row")
  end)

  it("aligns even-height operators on the lower of the two middle rows", function()
    local lines = m.stack("(x + y)^n = \\sum_{k=0}^{n} \\binom{n}{k}")
    local function rowof(g)
      for i, l in ipairs(lines) do
        if l:find(g, 1, true) then
          return i
        end
      end
    end
    -- the 2-row sigma core and the 2-row binom round their centres the same way
    -- (down to the lower middle row), so their bottoms share the = row and their
    -- tops share the row above, rather than the two sitting a row apart
    assert.equal(rowof("⎲"), rowof("⎛"), "sigma top and binom top share a row")
    assert.equal(rowof("⎳"), rowof("⎝"), "sigma bottom and binom bottom share a row")
    assert.equal(rowof("="), rowof("⎳"), "and the = sits on that lower middle row")
  end)
end)
