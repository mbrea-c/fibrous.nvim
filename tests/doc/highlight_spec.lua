-- First-class treesitter highlighting for fenced code blocks (fibrous.doc.
-- highlight). It turns code + a language into a fibrous span list using the
-- detached STRING parser, and degrades GRACEFULLY to nil when treesitter or the
-- language's parser/query is unavailable (e.g. the WASM docs site) — the
-- renderer then falls back to plain @markup.raw. No buffers, no window state.

local highlight = require("fibrous.doc.highlight")
local render = require("fibrous.doc.render")
local ast = require("fibrous.doc.ast")
local ui = require("fibrous.inline.components")

describe("fibrous.doc.highlight", function()
  it("returns nil (graceful) for a missing language or parser", function()
    assert.is_nil(highlight.code("x = 1", nil))
    assert.is_nil(highlight.code("x = 1", ""))
    assert.is_nil(highlight.code("x = 1", "not_a_real_language_xyz"))
  end)

  it("never errors, and returns a valid span list when it highlights", function()
    for _, case in ipairs({ { "local x = 1", "lua" }, { "", "lua" }, { "plain", "unknownlang" } }) do
      local spans = highlight.code(case[1], case[2])
      if spans ~= nil then
        assert.equal("table", type(spans))
      end
    end
  end)

  it("highlights lua (parser present in this environment)", function()
    local spans = highlight.code("local x = 1", "lua")
    assert.is_true(spans ~= nil, "lua code highlights when the parser is available")
    local styled = false
    for _, s in ipairs(spans) do
      if type(s) == "table" and s.hl then
        styled = true
      end
    end
    assert.is_true(styled, "at least one span carries a treesitter group")
    -- the flattened text is preserved verbatim
    local parts = {}
    for _, s in ipairs(spans) do
      parts[#parts + 1] = type(s) == "table" and s[1] or s
    end
    assert.equal("local x = 1", table.concat(parts))
  end)
end)

describe("code blocks highlight by default, degrading to plain", function()
  it("renders a ui.text with highlighted spans when a parser exists", function()
    local v = render.render(ast.code_block("lua", "local x = 1"), {})
    assert.equal(ui.text, v.comp)
    assert.is_false(v.props.wrap)
    assert.equal("table", type(v.props.text)) -- a span list, not a bare string
  end)

  it("renders plain @markup.raw when the language has no parser", function()
    local v = render.render(ast.code_block("unknownlang", "code here"), {})
    assert.equal(ui.text, v.comp)
    assert.equal("code here", v.props.text)
    assert.equal("@markup.raw", v.props.style.text_hl)
  end)
end)
