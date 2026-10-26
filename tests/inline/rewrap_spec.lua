local runtime = require("fibrous.reactive.runtime")
local Host = require("fibrous.inline.host")
local Layout = require("fibrous.inline.layout")
local ui = require("fibrous.inline.components")

describe("rewrapping without retained word tokens", function()
  local roots
  before_each(function() roots = {} end)
  after_each(function() for _, root in ipairs(roots) do root:unmount() end end)
  local function create(text, source, width)
    local size = { width = width }
    local host = Host.new({ get_size = function() return size end })
    local root = runtime.create_root(function()
      return { comp = ui.text, props = { text = text, wrap = true, source = source } }
    end, {}, { host = host })
    roots[#roots + 1] = root
    root:render()
    return host, size
  end

  it("keeps flattened text but does not retain token tables across resizes", function()
    local host, size = create({ "alpha beta gamma ", { ("delta epsilon "):rep(30), hl = "Title" } }, nil, 80)
    local text, ranges = host.tree._text, host.tree._ranges
    for _, width in ipairs({ 79, 50, 100, 33, 80 }) do
      size.width = width
      host.relayout()
      assert.is_nil(host.tree._words)
      assert.equal(text, host.tree._text)
      assert.rawequal(ranges, host.tree._ranges)
    end
  end)

  it("matches uncached wrapping, spans and provenance across many widths", function()
    local click = function() end
    local text = { " \talpha  beta\n\n", { "界面 café é   ", hl = "Title", on_click = click },
      { "a_very_long_identifier gamma\nlast line ", hl = "Comment" } }
    local source = { id = "words", offset = 30 }
    local host, size = create(text, source, 80)
    local raw = { kind = "text", text = text, props = { wrap = true, source = source } }
    for _, width in ipairs({ 70, 11, 6, 1, 29, 80, 37 }) do
      size.width = width
      host.relayout()
      Layout.compute(raw, { width = width })
      assert.same(raw.lines, host.tree.lines)
      assert.same(raw.line_runs, host.tree.line_runs)
      assert.same(raw.content_size, host.tree.content_size)
    end
  end)

  it("remeasures non-ASCII word widths when ambiwidth changes", function()
    local before = vim.o.ambiwidth
    local ok, err = pcall(function()
      vim.o.ambiwidth = "single"
      local text = ("alpha ··· beta "):rep(3)
      local host, size = create(text, nil, 35)
      vim.o.ambiwidth = "double"
      size.width = 18
      host.relayout()
      local raw = { kind = "text", text = text, props = { wrap = true } }
      Layout.compute(raw, { width = 18 })
      assert.same(raw.lines, host.tree.lines)
      assert.same(raw.content_size, host.tree.content_size)
    end)
    vim.o.ambiwidth = before
    if not ok then error(err, 0) end
  end)
end)
