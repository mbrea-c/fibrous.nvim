local runtime = require("fibrous.reactive.runtime")
local Host = require("fibrous.inline.host")
local Layout = require("fibrous.inline.layout")
local Spans = require("fibrous.inline.spans")
local ui = require("fibrous.inline.components")

describe("wrapping at unchanged effective widths", function()
  local roots
  before_each(function() roots = {} end)
  after_each(function() for _, root in ipairs(roots) do root:unmount() end end)
  local function create(app, width)
    local size = { width = width }
    local host = Host.new({ get_size = function() return size end })
    local root = runtime.create_root(app, {}, { host = host })
    roots[#roots + 1] = root
    root:render()
    return host, size
  end
  local function fixed(bounds)
    return function()
      return { comp = ui.col, children = {
        { comp = ui.col, props = bounds, children = {
          { comp = ui.paragraph, props = { text = { "several words with ", { "some styling", hl = "Title" } } } },
        } },
      } }
    end
  end

  it("keeps the wrapped lines and runs of a fixed-width descendant", function()
    local host, size = create(fixed({ width = 24 }), 100)
    local leaf = host.tree.children[1].children[1]
    local lines, runs = leaf.lines, leaf.line_runs
    size.width = 80
    host.relayout()
    assert.rawequal(lines, leaf.lines)
    assert.rawequal(runs, leaf.line_runs)
  end)

  it("does not reattribute a max-width-clamped descendant", function()
    local host, size = create(fixed({ max_width = 24 }), 100)
    local runs, count = Spans.runs, 0
    Spans.runs = function(...) count = count + 1; return runs(...) end
    local ok, err = pcall(function()
      for _, width in ipairs({ 90, 70, 50, 110 }) do size.width = width; host.relayout() end
    end)
    Spans.runs = runs
    if not ok then error(err, 0) end
    assert.equal(0, count)
  end)

  it("matches fresh mounts when measured and final flex widths differ", function()
    local function App()
      return { comp = ui.row, children = {
        { comp = ui.paragraph, props = { grow = 1, text = { "alpha beta gamma delta epsilon ", { "界面 café", hl = "Title" } } } },
        { comp = ui.paragraph, props = { grow = 1, text = "one two three four five six seven eight" } },
      } }
    end
    local host, size = create(App, 100)
    for _, width in ipairs({ 50, 80, 25, 100, 40 }) do
      size.width = width
      host.relayout()
      local fresh = create(App, width)
      assert.same(vim.api.nvim_buf_get_lines(fresh.bufnr, 0, -1, false),
        vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false))
      for i, child in ipairs(host.tree.children) do
        assert.same(fresh.tree.children[i].content_size, child.content_size)
        assert.same(fresh.tree.children[i].lines, child.lines)
        assert.same(fresh.tree.children[i].line_runs, child.line_runs)
      end
    end
  end)

  it("reflows fixed-width non-ASCII text after a width-policy change", function()
    local before = vim.o.ambiwidth
    local ok, err = pcall(function()
      vim.o.ambiwidth = "single"
      local text = ("alpha ··· beta "):rep(6)
      local function App()
        return { comp = ui.col, children = {
          { comp = ui.paragraph, props = { width = 24, text = text } },
        } }
      end
      local host, size = create(App, 100)
      vim.o.ambiwidth = "double"
      size.width = 80
      host.relayout()
      local raw = { kind = "text", text = text, props = { width = 24, wrap = true } }
      Layout.compute(raw, { width = 24 })
      assert.same(raw.lines, host.tree.children[1].lines)
    end)
    vim.o.ambiwidth = before
    if not ok then error(err, 0) end
  end)

  it("does not reuse wrapping for mutable raw text at the same width", function()
    local tree = { kind = "text", text = "old words", props = { wrap = true } }
    Layout.compute(tree, { width = 12 })
    tree.text = "entirely different words"
    Layout.compute(tree, { width = 12 })
    assert.same({ "entirely", "different", "words" }, tree.lines)
  end)
end)
