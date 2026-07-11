-- The shared document renderer (fibrous.doc.render): a neutral document AST to
-- fibrous vnodes. Blocks become col/paragraph/text/container; inline marks
-- become SpanStyle spans over Neovim's standard @markup.* groups; links become
-- interactive spans (role + on_click). Pure: props in, vnodes out.

local ast = require("fibrous.doc.ast")
local render = require("fibrous.doc.render")
local ui = require("fibrous.inline.components")

describe("fibrous.doc.render inline", function()
  it("leaves plain text bare and wraps marks in @markup.* spans", function()
    local sp = render.inline({ ast.text("hi "), ast.strong({ ast.text("bold") }) }, {})
    assert.equal("hi ", sp[1])
    assert.equal("bold", sp[2][1])
    assert.equal("@markup.strong", sp[2].style.text_hl)
  end)

  it("renders code spans with @markup.raw and softbreaks as spaces", function()
    local sp = render.inline({ ast.code_span("f()"), ast.softbreak(), ast.text("x") }, {})
    assert.equal("f()", sp[1][1])
    assert.equal("@markup.raw", sp[1].style.text_hl)
    assert.equal(" ", sp[2])
    assert.equal("x", sp[3])
  end)

  it("makes a link an interactive span that fires on_link with its url", function()
    local opened
    local sp = render.inline({ ast.link("http://x", nil, { ast.text("go") }) }, {
      on_link = function(u)
        opened = u
      end,
    })
    assert.equal("go", sp[1][1])
    assert.equal("link", sp[1].role)
    assert.equal("@markup.link", sp[1].style.text_hl)
    assert.equal("function", type(sp[1].on_click))
    sp[1].on_click()
    assert.equal("http://x", opened)
  end)
end)

describe("fibrous.doc.render blocks", function()
  it("renders a document as a col of blocks", function()
    local doc = ast.document({
      ast.heading(2, { ast.text("Title") }),
      ast.paragraph({ ast.text("body") }),
      ast.code_block("lua", "x = 1"),
    })
    local v = render.render(doc, {})
    assert.equal(ui.col, v.comp)
    assert.equal(3, #v.children)

    local h = v.children[1]
    assert.equal(ui.paragraph, h.comp)
    assert.equal("@markup.heading.2", h.props.style.text_hl)

    local cb = v.children[3]
    assert.equal(ui.text, cb.comp)
    assert.is_false(cb.props.wrap)
    assert.equal("x = 1", cb.props.text)
    assert.equal("@markup.raw", cb.props.style.text_hl)
  end)

  it("renders an unordered list with markers and a task list with checkboxes", function()
    local list = ast.list({
      ordered = false,
      tight = true,
      items = {
        ast.list_item({ ast.paragraph({ ast.text("one") }) }, nil),
        ast.list_item({ ast.paragraph({ ast.text("done") }) }, true),
      },
    })
    local v = render.render(list, {})
    assert.equal(ui.col, v.comp)
    assert.equal(2, #v.children)

    -- first item: a bullet marker label + a content col
    local row1 = v.children[1]
    assert.equal(ui.row, row1.comp)
    assert.equal(ui.label, row1.children[1].comp)

    -- task item: the marker is a checkbox reflecting `checked`
    local row2 = v.children[2]
    assert.equal(ui.checkbox, row2.children[1].comp)
    assert.is_true(row2.children[1].props.checked)
  end)
end)
