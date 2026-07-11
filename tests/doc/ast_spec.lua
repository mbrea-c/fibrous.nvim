-- The format-neutral document AST (fibrous.doc.ast): the contract every parser
-- emits and the renderer consumes. Small constructors that stamp a `type` and
-- carry the node's fields — markdown is just the first parser to target it.

local ast = require("fibrous.doc.ast")

describe("fibrous.doc.ast inline nodes", function()
  it("builds text, code_span, and the mark wrappers", function()
    assert.same({ type = "text", text = "hi" }, ast.text("hi"))
    assert.same({ type = "code_span", text = "f()" }, ast.code_span("f()"))
    assert.same({ type = "strong", children = { { type = "text", text = "x" } } }, ast.strong({ ast.text("x") }))
    assert.same({ type = "emph", children = {} }, ast.emph({}))
    assert.same({ type = "strikethrough", children = {} }, ast.strikethrough({}))
    assert.same({ type = "softbreak" }, ast.softbreak())
    assert.same({ type = "hardbreak" }, ast.hardbreak())
  end)

  it("builds links and images with their attributes", function()
    local l = ast.link("http://x", "t", { ast.text("go") })
    assert.equal("link", l.type)
    assert.equal("http://x", l.url)
    assert.equal("t", l.title)
    assert.same({ { type = "text", text = "go" } }, l.children)

    local img = ast.image("i.png", "alt", nil)
    assert.equal("image", img.type)
    assert.equal("i.png", img.url)
    assert.equal("alt", img.alt)
  end)
end)

describe("fibrous.doc.ast block nodes", function()
  it("builds leaf and container blocks", function()
    assert.same({ type = "heading", level = 2, children = {} }, ast.heading(2, {}))
    assert.same({ type = "paragraph", children = {} }, ast.paragraph({}))
    assert.same({ type = "code_block", lang = "lua", text = "x=1" }, ast.code_block("lua", "x=1"))
    assert.same({ type = "blockquote", children = {} }, ast.blockquote({}))
    assert.same({ type = "thematic_break" }, ast.thematic_break())

    local doc = ast.document({ ast.paragraph({}) })
    assert.equal("document", doc.type)
    assert.equal(1, #doc.children)
  end)

  it("builds lists with ordering, tightness, and task items", function()
    local plain = ast.list_item({ ast.paragraph({}) }, nil)
    assert.equal("list_item", plain.type)
    assert.is_nil(plain.checked)

    local task = ast.list_item({ ast.paragraph({}) }, false)
    assert.equal(false, task.checked)

    local list = ast.list({ ordered = true, start = 3, tight = true, items = { plain, task } })
    assert.equal("list", list.type)
    assert.is_true(list.ordered)
    assert.equal(3, list.start)
    assert.is_true(list.tight)
    assert.equal(2, #list.items)
  end)

  it("builds a table with per-column alignment", function()
    local t = ast.table({
      align = { "left", "right" },
      header = { { ast.text("a") }, { ast.text("b") } },
      rows = { { { ast.text("1") }, { ast.text("2") } } },
    })
    assert.equal("table", t.type)
    assert.same({ "left", "right" }, t.align)
    assert.equal(2, #t.header)
    assert.equal(1, #t.rows)
  end)
end)
