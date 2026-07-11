-- Math in markdown: $...$ inline and $$...$$ display, parsed into neutral AST
-- nodes (math_inline / math_block) and rendered by fibrous.doc.math. Inline math
-- becomes a single-line span; display math a centered block of stacked lines.

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

describe("markdown math rendering", function()
  it("renders inline math as a single-line span", function()
    local sp = render.inline({ { type = "math_inline", tex = "x^2" } }, {})
    -- flattened to the unicode single-line form
    local text = type(sp[1]) == "table" and sp[1][1] or sp[1]
    assert.equal("x²", text)
  end)

  it("renders a display block as a centered col of stacked lines", function()
    local v = render.render({ type = "math_block", tex = "\\frac{a}{b}" }, {})
    assert.equal(ui.col, v.comp)
    -- one label per stacked line (a, ─, b)
    assert.equal(3, #v.children)
    assert.equal(ui.label, v.children[1].comp)
  end)
end)
