-- The inline phase of the markdown parser: a run of inline source text to
-- fibrous.doc.ast inline nodes (emphasis, strong, code spans, links, images,
-- autolinks, strikethrough, escapes, soft/hard breaks). Pure, no Neovim.

local inline = require("fibrous.markdown.inline")

describe("fibrous.markdown.inline", function()
  it("returns a single text node for plain text", function()
    assert.same({ { type = "text", text = "hello world" } }, inline.parse("hello world"))
  end)

  it("parses strong and emphasis", function()
    local n = inline.parse("a **b** c *d*")
    assert.equal("a ", n[1].text)
    assert.equal("strong", n[2].type)
    assert.equal("b", n[2].children[1].text)
    assert.equal(" c ", n[3].text)
    assert.equal("emph", n[4].type)
    assert.equal("d", n[4].children[1].text)
  end)

  it("parses code spans literally (no inline inside)", function()
    local n = inline.parse("call `f(*x*)` now")
    assert.equal("code_span", n[2].type)
    assert.equal("f(*x*)", n[2].text)
  end)

  it("parses links with an optional title", function()
    local n = inline.parse([[see [docs](http://x "t") ok]])
    assert.equal("link", n[2].type)
    assert.equal("http://x", n[2].url)
    assert.equal("t", n[2].title)
    assert.equal("docs", n[2].children[1].text)
  end)

  it("parses images", function()
    local n = inline.parse("![alt](img.png)")
    assert.equal("image", n[1].type)
    assert.equal("alt", n[1].alt)
    assert.equal("img.png", n[1].url)
  end)

  it("parses autolinks", function()
    local n = inline.parse("<http://x.com>")
    assert.equal("link", n[1].type)
    assert.equal("http://x.com", n[1].url)
    assert.equal("http://x.com", n[1].children[1].text)
  end)

  it("parses strikethrough (GFM)", function()
    local n = inline.parse("~~gone~~")
    assert.equal("strikethrough", n[1].type)
    assert.equal("gone", n[1].children[1].text)
  end)

  it("leaves intraword underscores literal (snake_case identifiers)", function()
    -- One paragraph, two identifiers: without flanking checks the first _
    -- opened emphasis and the next one closed it, eating both underscores.
    assert.same(
      { { type = "text", text = "compare pending_edits against first_pending_at" } },
      inline.parse("compare pending_edits against first_pending_at")
    )
    assert.same({ { type = "text", text = "_foo_bar" } }, inline.parse("_foo_bar"))
    assert.same({ { type = "text", text = "foo__bar__baz" } }, inline.parse("foo__bar__baz"))
  end)

  it("still emphasizes word-flanked underscores and intraword asterisks", function()
    local n = inline.parse("a _b_ c")
    assert.equal("emph", n[2].type)
    assert.equal("b", n[2].children[1].text)
    local strong = inline.parse("__init__")
    assert.equal("strong", strong[1].type)
    assert.equal("init", strong[1].children[1].text)
    -- * (unlike _) may bind inside a word
    local intra = inline.parse("a*b*c")
    assert.equal("emph", intra[2].type)
    assert.equal("b", intra[2].children[1].text)
  end)

  it("leaves space-flanked delimiters literal", function()
    assert.same({ { type = "text", text = "2 * 3 * 4" } }, inline.parse("2 * 3 * 4"))
    assert.same({ { type = "text", text = "a ~~ b ~~ c" } }, inline.parse("a ~~ b ~~ c"))
    -- an invalid closer candidate is skipped, not fatal: the later valid
    -- one closes (CommonMark: _a _b_ emphasizes "a _b")
    local n = inline.parse("_a _b_")
    assert.equal("emph", n[1].type)
    assert.equal("a _b", n[1].children[1].text)
  end)

  it("honors backslash escapes", function()
    assert.same({ { type = "text", text = "a * b" } }, inline.parse([[a \* b]]))
  end)

  it("turns a newline into a softbreak, trailing spaces into a hardbreak", function()
    local soft = inline.parse("a\nb")
    assert.equal("softbreak", soft[2].type)
    local hard = inline.parse("a  \nb")
    assert.equal("hardbreak", hard[2].type)
  end)
end)
