-- ui.code (fibrous.doc.snippet): a source snippet with treesitter
-- highlighting, an optional file-reference header (click to jump), and a
-- line-number gutter whose numbers MATCH the referenced code.

local mount = require("fibrous.inline.mount")
local snippet = require("fibrous.doc.snippet")
local ui = require("fibrous.inline.components")

-- A single-render ctx stub: components under test only use use_ref.
local function stub_ctx()
  return {
    use_ref = function(init)
      return { current = init }
    end,
  }
end

-- The snippet tree is col{ header?, row{ gutter, code } | code, marker? }.
-- These pick the pieces out by shape so the specs read declaratively.
local function body_row(v)
  for _, child in ipairs(v.children) do
    if child.comp == ui.row then
      return child
    end
  end
end

local function labels_of(v)
  local out = {}
  for _, child in ipairs(v.children) do
    if child.comp == ui.label then
      out[#out + 1] = child
    end
  end
  return out
end

local function span_text(text)
  if type(text) == "string" then
    return text
  end
  local parts = {}
  for _, s in ipairs(text) do
    parts[#parts + 1] = type(s) == "table" and s[1] or s
  end
  return table.concat(parts)
end

describe("fibrous.doc.snippet", function()
  it("numbers the gutter from ref.start_line, right-aligned", function()
    local v = snippet.component(stub_ctx(), {
      code = "local a = 1\nlocal b = 2\nlocal c = 3",
      ref = { path = "foo.lua", start_line = 9 },
    })
    local row = body_row(v)
    assert.is_not_nil(row)
    local gutter = row.children[1]
    assert.equal(" 9\n10\n11", gutter.props.text)
    assert.equal("FibrousCodeGutter", gutter.props.style.text_hl)
    assert.is_false(gutter.props.wrap)
  end)

  it("headers with the path and the full range, and the header jumps", function()
    assert.equal(
      "foo.lua:9-11",
      snippet.header_label({ code = "", ref = { path = "foo.lua", start_line = 9 } }, 3)
    )
    assert.equal(
      "foo.lua:9",
      snippet.header_label({ code = "", ref = { path = "foo.lua", start_line = 9 } }, 1)
    )
    -- no start: the path alone (a range counted from 1 would be a lie)
    assert.equal("foo.lua", snippet.header_label({ code = "", ref = { path = "foo.lua" } }, 3))
    -- no ref (or header = false): no header at all
    assert.is_nil(snippet.header_label({ code = "" }, 3))
    assert.is_nil(snippet.header_label({ code = "", ref = { path = "f" }, header = false }, 3))

    local opened
    local v = snippet.component(stub_ctx(), {
      code = "x = 1",
      ref = { path = "foo.lua", start_line = 4 },
      on_open = function(ref)
        opened = ref
      end,
    })
    local header = v.children[1]
    assert.equal(ui.label, header.comp)
    local span = header.props.text[1]
    assert.equal("foo.lua:4", span[1])
    assert.equal("link", span.role)
    span.on_click()
    assert.equal("foo.lua", opened.path)
    assert.equal(4, opened.start_line)
  end)

  it("infers the language from ref.path and highlights", function()
    local v = snippet.component(stub_ctx(), {
      code = "local x = 1",
      ref = { path = "foo.lua", start_line = 1 },
    })
    local code = body_row(v).children[2]
    assert.equal(ui.text, code.comp)
    assert.equal("table", type(code.props.text)) -- a span list, not a bare string
    assert.equal("local x = 1", span_text(code.props.text))
  end)

  it("degrades to plain @markup.raw without a parser", function()
    local v = snippet.component(stub_ctx(), { code = "plain text", lang = "not_a_real_language_xyz" })
    local code = body_row(v).children[2]
    assert.equal("plain text", code.props.text)
    assert.equal("@markup.raw", code.props.style.text_hl)
  end)

  it("drops the gutter with line_numbers = false", function()
    local v = snippet.component(stub_ctx(), { code = "x = 1\ny = 2", line_numbers = false })
    assert.is_nil(body_row(v))
    -- the code node sits directly in the col
    local code = v.children[1]
    assert.equal(ui.text, code.comp)
  end)

  it("caps at max_lines with a dim marker, gutter included", function()
    local v = snippet.component(stub_ctx(), {
      code = "a\nb\nc\nd\ne",
      lang = "not_a_real_language_xyz",
      max_lines = 2,
    })
    local row = body_row(v)
    assert.equal("1\n2", row.children[1].props.text)
    assert.equal("a\nb", row.children[2].props.text)
    local marker = labels_of(v)[1]
    assert.is_not_nil(marker)
    assert.truthy(marker.props.text:find("3 more", 1, true))
  end)

  it("keeps highlighted multi-line snippets line-aligned when truncated", function()
    local v = snippet.component(stub_ctx(), {
      code = "local a = 1\nlocal b = 2\nlocal c = 3",
      lang = "lua",
      max_lines = 2,
    })
    local code = body_row(v).children[2]
    assert.equal("local a = 1\nlocal b = 2", span_text(code.props.text))
  end)

  it("passes layout/style props through to the outer col", function()
    local v = snippet.component(stub_ctx(), { code = "x", grow = 1, style = { padding = { left = 2 } } })
    assert.equal(1, v.props.grow)
    assert.equal(2, v.props.style.padding.left)
  end)

  it("mounts through ui.code: numbers beside the source", function()
    local function App()
      return {
        comp = ui.code,
        props = { code = "local x = 1\nreturn x", ref = { path = "foo.lua", start_line = 4 } },
      }
    end
    local handle = mount.floating(App, {}, { width = 40, height = 5 })
    local text = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("4 local x = 1", 1, true), "gutter number sits beside its line")
    assert.truthy(text:find("5 return x", 1, true))
    assert.truthy(text:find("foo.lua:4-5", 1, true), "header shows the reference")
    handle.unmount()
  end)
end)
