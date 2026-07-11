-- The ui.markdown builtin: markdown source in, rich fibrous blocks out. A
-- stateful wrapper (it caches the parsed AST on a ref) that ties the parser
-- (fibrous.markdown) to the shared renderer (fibrous.doc.render). Markers are
-- consumed by the parser, so the rendered buffer shows clean text.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local targets = require("fibrous.targets")

local function text_of(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

describe("ui.markdown", function()
  it("renders markdown source as rich blocks with markers consumed", function()
    local function App()
      return { comp = ui.markdown, props = { text = "# Title\n\nsome **bold** text" } }
    end
    local handle = mount.floating(App, {}, { width = 40, height = 6 })
    local t = text_of(handle.bufnr)
    assert.truthy(t:find("Title", 1, true), "heading text shown")
    assert.truthy(t:find("some bold text", 1, true), "inline markers consumed")
    assert.falsy(t:find("*", 1, true), "no literal asterisks left")
    handle.unmount()
  end)

  it("exposes links as flash targets", function()
    local function App()
      return {
        comp = ui.markdown,
        props = { text = "see [the docs](http://x) now", on_link = function() end },
      }
    end
    local handle = mount.floating(App, {}, { width = 40, height = 4 })
    local links = targets.targets({ winid = handle.winid, kinds = { "link" } })
    assert.equal(1, #links)
    assert.equal("link", links[1].kind)
    handle.unmount()
  end)

  it("renders plain, unparsed text while live (streaming)", function()
    local function App()
      return { comp = ui.markdown, props = { text = "# not yet", live = true } }
    end
    local handle = mount.floating(App, {}, { width = 40, height = 4 })
    -- live path shows the raw source (parse deferred until settled)
    assert.truthy(text_of(handle.bufnr):find("# not yet", 1, true))
    handle.unmount()
  end)
end)
