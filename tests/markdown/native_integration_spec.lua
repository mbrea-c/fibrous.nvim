-- The Nix native check runs these against the installed module, not a dev build.
if not vim.env.FIBROUS_TEST_NATIVE then
  return
end
vim.opt.runtimepath:append(vim.env.FIBROUS_TEST_NATIVE)

local fibrous = require("fibrous")
local Host = require("fibrous.inline.host")
local runtime = require("fibrous.reactive.runtime")
local ui = require("fibrous.inline.components")
local sources = require("fibrous.sources")
local handles = {}

local function mounted(props, native)
  local size = { width = 60 }
  local host = Host.new({
    native_markdown = native,
    get_size = function()
      return size
    end,
  })
  local root = runtime.create_root(ui.markdown, props, { host = host })
  root:render()
  handles[#handles + 1] = root
  return host, root, size
end

local function marks(host)
  local result = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, host.ns, 0, -1, { details = true })) do
    result[#result + 1] = { m[2], m[3], m[4].end_col, m[4].hl_group }
  end
  table.sort(result, function(a, b)
    for i = 1, 4 do
      if a[i] ~= b[i] then
        return a[i] < b[i]
      end
    end
    return false
  end)
  return result
end

local function parity(native, lua)
  assert.same(lua.canvas_lines, native.canvas_lines)
  assert.same(marks(lua), marks(native))
end

describe("installed Rust Markdown renderer", function()
  after_each(function()
    for _, root in ipairs(handles) do
      root:unmount()
    end
    handles = {}
    fibrous.setup({ native_markdown = false })
  end)

  it("renders narrow and wide Markdown with identical highlights and source ranges", function()
    local text =
      "# Héllo\n\nA **bold** paragraph with [wide 世界 links](https://example.com) and more words.\n\n> quoted text\n\n1. first item\n2. second item\n\n| left | right |\n| :--- | ---: |\n| 界 | value |"
    local n, _, ns = mounted({ text = text, source = { id = "native-source" } }, true)
    local l, _, ls = mounted({ text = text, source = { id = "lua-source" } }, false)
    for _, w in ipairs({ 30, 17, 1, 2, 60, 44 }) do
      ns.width, ls.width = w, w
      n.relayout()
      l.relayout()
      assert.equal("rust", n.markdown_backend)
      parity(n, l)
      for p = 0, #text - 1 do
        local a, b = sources.project("native-source", p, p + 1), sources.project("lua-source", p, p + 1)
        for _, loc in ipairs(a) do
          loc.bufnr = nil
        end
        for _, loc in ipairs(b) do
          loc.bufnr = nil
        end
        assert.same(b, a)
      end
    end
  end)

  it("returns to Lua for edits, streaming, and unsupported revisions", function()
    local n, nr, ns = mounted({ text = "old **text**" }, true)
    local l, lr, ls = mounted({ text = "old **text**" }, false)
    ns.width, ls.width = 20, 20
    n.relayout()
    l.relayout()
    assert.equal("rust", n.markdown_backend)
    for _, props in ipairs({
      { text = "new **text** and more" },
      { text = "streaming **text", live = true },
      { text = "settled **text**" },
      { text = "---\n\nunsupported rule" },
      { text = "styled text", style = { padding = 2, hl = "Normal" } },
      { text = "transparent quote", style = { border = { left = true, hl = false }, padding = { left = 1 } } },
      { text = "back to plain text" },
    }) do
      nr:set_props(props)
      lr:set_props(props)
      assert.equal("lua", n.markdown_backend)
      parity(n, l)
      ns.width, ls.width = ns.width == 20 and 35 or 20, ls.width == 20 and 35 or 20
      n.relayout()
      l.relayout()
      parity(n, l)
    end
    assert.equal("rust", n.markdown_backend)
  end)

  it("preserves whole-entry comment anchors instead of silently dropping them", function()
    local entry = { id = "entry-anchor", data = { entry_id = "entry-anchor" } }
    local host, _, size = mounted({ text = "$$\n\\frac{a}{b}\n$$", source_entry = entry }, true)
    assert.equal(1, #sources.entry_locations("entry-anchor"))
    size.width = 25
    host.relayout()
    assert.equal(1, #sources.entry_locations("entry-anchor"))
    assert.equal("lua", host.markdown_backend)
  end)

  it("does not attach to fixed-mode or arbitrary UI trees", function()
    fibrous.setup({ native_markdown = true })
    local size = { width = 40, height = 10 }
    local host = Host.new({
      get_size = function()
        return size
      end,
    })
    local root = runtime.create_root(ui.markdown, { text = "hello **world**" }, { host = host })
    handles[#handles + 1] = root
    root:render()
    size.width = 30
    host.relayout()
    assert.equal("lua", host.markdown_backend)

    local other = Host.new({
      get_size = function()
        return { width = size.width }
      end,
    })
    local r = runtime.create_root(ui.button, { label = "not Markdown" }, { host = other })
    handles[#handles + 1] = r
    r:render()
    size.width = 20
    other.relayout()
    assert.equal("lua", other.markdown_backend)
  end)
end)
