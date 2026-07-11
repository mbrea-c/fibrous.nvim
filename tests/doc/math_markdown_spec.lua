-- Math in markdown: $...$ inline and $$...$$ display, parsed into neutral AST
-- nodes (math_inline / math_block) and rendered by fibrous.doc.math. Math is split
-- into spans so variables italicise (FibrousMathVariable) while the rest keeps the
-- user's @markup.math; display math is a centered block of stacked lines.

local md = require("fibrous.markdown")
local render = require("fibrous.doc.render")
local ui = require("fibrous.inline.components")

describe("markdown math parsing", function()
  it("parses inline $...$ into a math_inline node", function()
    local doc = md.parse("energy $E = mc^2$ here")
    local p = doc.children[1]
    assert.equal("paragraph", p.type)
    assert.equal("math_inline", p.children[2].type)
    assert.equal("E = mc^2", p.children[2].tex)
  end)

  it("does not eat dollar signs in prose", function()
    local doc = md.parse("it cost $5 and $10 total")
    local p = doc.children[1]
    -- no valid inline math (digit right after $, space before close), so it stays text
    local has_math = false
    for _, n in ipairs(p.children) do
      has_math = has_math or n.type == "math_inline"
    end
    assert.falsy(has_math, "prose dollars must not become inline math")
  end)

  it("parses a $$...$$ display block", function()
    local doc = md.parse("before\n\n$$\n\\frac{a}{b}\n$$\n\nafter")
    local kinds = {}
    for _, b in ipairs(doc.children) do
      kinds[#kinds + 1] = b.type
    end
    assert.same({ "paragraph", "math_block", "paragraph" }, kinds)
    assert.truthy(doc.children[2].tex:find("frac", 1, true))
  end)
end)

-- text + hl of a span (bare string spans carry no hl)
local function span_text(sp)
  return type(sp) == "table" and sp[1] or sp
end
local function span_hl(sp)
  return type(sp) == "table" and sp.style and sp.style.text_hl or nil
end
local function joined(spans)
  local out = {}
  for _, sp in ipairs(spans) do
    out[#out + 1] = span_text(sp)
  end
  return table.concat(out)
end

describe("markdown math rendering", function()
  it("splits inline math into variable and non-variable spans", function()
    local sp = render.inline({ { type = "math_inline", tex = "x^2" } }, {})
    assert.equal("x²", joined(sp)) -- the unicode single-line form, across spans
    -- the variable x italicises via FibrousMathVariable; the ² stays @markup.math
    assert.equal("x", span_text(sp[1]))
    assert.equal("FibrousMathVariable", span_hl(sp[1]))
    assert.equal("@markup.math", span_hl(sp[2]))
  end)

  it("keeps \\text content out of the variable (italic) spans", function()
    local sp = render.inline({ { type = "math_inline", tex = "\\text{if } x" } }, {})
    assert.equal("if  x", joined(sp)) -- \text's trailing space + the literal math space

    -- the only FibrousMathVariable span is the trailing x, never the \text letters
    local vars = {}
    for _, s in ipairs(sp) do
      if span_hl(s) == "FibrousMathVariable" then
        vars[#vars + 1] = span_text(s)
      end
    end
    assert.same({ "x" }, vars)
  end)

  it("renders a display block as a centered col of stacked lines", function()
    local v = render.render({ type = "math_block", tex = "\\frac{a}{b}" }, {})
    assert.equal(ui.col, v.comp)
    -- one label per stacked line (a, ─, b)
    assert.equal(3, #v.children)
    assert.equal(ui.label, v.children[1].comp)
    -- the numerator variable a rides a FibrousMathVariable span
    local row1 = v.children[1].props.text
    assert.equal("a", span_text(row1[1]))
    assert.equal("FibrousMathVariable", span_hl(row1[1]))
  end)
end)
