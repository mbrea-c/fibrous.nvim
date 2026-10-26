local runtime = require("fibrous.reactive.runtime")
local Host = require("fibrous.inline.host")
local Layout = require("fibrous.inline.layout")
local Spans = require("fibrous.inline.spans")
local Sources = require("fibrous.sources")
local ui = require("fibrous.inline.components")

describe("host text preparation across resize", function()
  local roots
  before_each(function() roots = {} end)
  after_each(function() for _, root in ipairs(roots) do root:unmount() end end)
  local function create(component, props, width)
    local size = { width = width }
    local host = Host.new({ get_size = function() return size end })
    local root = runtime.create_root(component, props, { host = host })
    roots[#roots + 1] = root
    root:render()
    return host, root, size
  end
  local function lines(host) return vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false) end

  it("does not flatten unchanged nested Markdown spans again on width changes", function()
    local text = "# title\n\nsome **bold** words and a [link](url) in a paragraph"
    local host, _, size = create(function()
      return { comp = ui.markdown, props = { text = text, source = { id = "cached", text = text } } }
    end, {}, 60)
    local flatten, count = Spans.flatten, 0
    Spans.flatten = function(...) count = count + 1; return flatten(...) end
    local ok, err = pcall(function()
      for _, width in ipairs({ 20, 45, 12, 60 }) do size.width = width; host.relayout() end
    end)
    Spans.flatten = flatten
    if not ok then error(err, 0) end
    assert.equal(0, count)
  end)

  it("reuses nowrap lines and source runs when only the available width changes", function()
    local host, _, size = create(function()
      return { comp = ui.text, props = { text = { { "界é\ncode", hl = "Title" } },
        source = { id = "nowrap" }, wrap = false } }
    end, {}, 30)
    local before_lines, before_runs = host.tree.lines, host.tree.line_runs
    size.width = 20
    host.relayout()
    assert.rawequal(before_lines, host.tree.lines)
    assert.rawequal(before_runs, host.tree.line_runs)
  end)

  it("remeasures nowrap non-ASCII display size without rebuilding lines or runs", function()
    local before = vim.o.ambiwidth
    local ok, err = pcall(function()
      vim.o.ambiwidth = "single"
      local function App()
        return { comp = ui.row, children = {
          { comp = ui.text, props = { text = { { "···", hl = "Title" } }, wrap = false } },
          { comp = ui.label, props = { text = "after" } },
        } }
      end
      local host, _, size = create(App, {}, 30)
      local leaf = host.tree.children[1]
      local old_lines, old_runs = leaf.lines, leaf.line_runs
      vim.o.ambiwidth = "double"
      size.width = 20
      host.relayout()
      local fresh = create(App, {}, 20)
      assert.same(fresh.tree.children[1].content_size, leaf.content_size)
      assert.same(lines(fresh), lines(host))
      assert.rawequal(old_lines, leaf.lines)
      assert.rawequal(old_runs, leaf.line_runs)
    end)
    vim.o.ambiwidth = before
    if not ok then error(err, 0) end
  end)

  it("invalidates prepared spans when text, styling, handlers or source change", function()
    local click1, click2 = function() end, function() end
    local function App(_, props)
      return { comp = ui.paragraph, props = { text = {
        { props.text, hl = props.hl, on_click = props.click } }, source = props.source } }
    end
    local first = { text = "old words", hl = "Title", click = click1, source = { id = "before" } }
    local host, root, size = create(App, first, 30)
    size.width = 8
    host.relayout()
    local next_props = { text = "new words changed", hl = "Comment", click = click2,
      source = { id = "after", offset = 30 } }
    root:set_props(next_props)
    local fresh = create(App, next_props, 8)
    assert.same(lines(fresh), lines(host))
    assert.equal("Comment", host.tree.line_runs[1][1].hl)
    assert.rawequal(click2, host.tree.line_runs[1][1].on_click)
    assert.equal(30, host.tree.line_runs[1][1].source_positions[1])
    assert.same({}, Sources.project("before", 0, 3))
    assert.is_true(#Sources.project("after", 30, 33) > 0)
  end)

  it("still recomputes mutable raw layout trees without a host cache contract", function()
    local span = { "old", hl = "Title" }
    local source = { id = "raw", offset = 0 }
    local tree = { kind = "text", text = { span }, props = { source = source, wrap = false } }
    Layout.compute(tree, { width = 30 })
    span[1], span.hl, source.offset = "changed", "Comment", 50
    Layout.compute(tree, { width = 20 })
    assert.same({ "changed" }, tree.lines)
    assert.equal("Comment", tree.line_runs[1][1].hl)
    assert.equal(50, tree.line_runs[1][1].source_positions[1])
  end)

  it("does not cache width-generated fill content", function()
    local host, _, size = create(function()
      return { comp = ui.text, props = { fill = function(width) return ("x"):rep(width) end } }
    end, {}, 20)
    size.width = 7
    host.relayout()
    assert.equal("xxxxxxx", host.tree.lines[1])
  end)
end)
