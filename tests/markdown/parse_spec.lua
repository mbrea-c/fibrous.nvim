-- End-to-end: fibrous.markdown.parse(source) -> fibrous.doc.ast document. The
-- orchestrator runs the block phase, then the inline phase over each leaf, and
-- lowers the whole thing into the neutral document AST the renderer consumes.

local md = require("fibrous.markdown")

describe("fibrous.markdown.parse", function()
  it("produces a document AST with inline content parsed", function()
    local doc = md.parse("# Title\n\nsome **bold** and a [link](http://x)")
    assert.equal("document", doc.type)
    assert.equal(2, #doc.children)

    local h = doc.children[1]
    assert.equal("heading", h.type)
    assert.equal(1, h.level)
    assert.equal("Title", h.children[1].text)

    local p = doc.children[2]
    assert.equal("paragraph", p.type)
    -- text "some ", strong[bold], text " and a ", link
    assert.equal("strong", p.children[2].type)
    assert.equal("bold", p.children[2].children[1].text)
    assert.equal("link", p.children[4].type)
    assert.equal("http://x", p.children[4].url)
  end)

  it("lowers lists (including task items) end to end", function()
    local doc = md.parse("- one\n- [x] done")
    local list = doc.children[1]
    assert.equal("list", list.type)
    assert.is_nil(list.items[1].checked)
    assert.equal(true, list.items[2].checked)
    assert.equal("one", list.items[1].children[1].children[1].text)
  end)

  it("lowers a table end to end, with inline cell content parsed", function()
    local doc = md.parse("| A | B |\n| --- | --- |\n| **x** | y |")
    local t = doc.children[1]
    assert.equal("table", t.type)
    assert.equal("A", t.header[1][1].text)
    -- cell inline is parsed: **x** becomes a strong node
    assert.equal("strong", t.rows[1][1][1].type)
    assert.equal("y", t.rows[1][2][1].text)
  end)

  it("keeps fenced code verbatim (no inline parse)", function()
    local doc = md.parse("```\na * b _c_\n```")
    local cb = doc.children[1]
    assert.equal("code_block", cb.type)
    assert.equal("a * b _c_", cb.text)
  end)
end)
