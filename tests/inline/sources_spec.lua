local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

describe("logical document sources", function()
  local apps
  before_each(function() apps = {} end)
  after_each(function() for _, app in ipairs(apps) do app.unmount() end end)
  local function open(text, width)
    local function Doc()
      return { comp = ui.markdown, props = { text = text, source = { id = "doc", text = text } } }
    end
    local app = mount.floating(Doc, {}, { width = width or 36, height = 20, mode = "scroll" })
    apps[#apps + 1] = app
    return app
  end
  local function select_text(app, needle)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)) do
      local col = line:find(needle, 1, true)
      if col then return require("fibrous.sources").resolve(app.bufnr,
        { lnum = row, end_lnum = row, col = col, end_col = col + #needle - 1 }) end
    end
    error("missing rendered text: " .. needle)
  end

  it("maps rich selections to original bytes without confusing repeated link destinations", function()
    local text = "same [same](same) **same** final"
    local app = open(text)
    local found = select_text(app, "final")
    assert.equal(1, #found)
    assert.equal(text:find("final", 1, true) - 1, found[1].start_byte)
    local bold = select_text(app, "same final")
    assert.equal(text:find("same**", 1, true) - 1, bold[1].start_byte)
    assert.equal(#text, bold[1].end_byte)
  end)

  it("projects a source range after reflow and ignores generated gutters", function()
    local text = "- first **selected** word\n- next"
    local app = open(text, 30)
    local selected = select_text(app, "selected")[1]
    vim.api.nvim_win_set_width(app.winid, 16)
    app.relayout()
    local locations = require("fibrous.sources").project("doc", selected.start_byte, selected.end_byte)
    assert.is_true(#locations > 0)
    local joined = {}
    for _, loc in ipairs(locations) do
      if loc.bufnr == app.bufnr then
        joined[#joined + 1] = vim.api.nvim_buf_get_text(loc.bufnr, loc.row, loc.start_col, loc.row, loc.end_col, {})[1]
      end
    end
    assert.equal("selected", table.concat(joined))
  end)

  it("keeps code, escaping, UTF-8 and CRLF source positions exact", function()
    local fence = string.char(96):rep(3)
    local text = "# head\r\n\r\n> - escaped \\*literal\\* 界é\r\n\r\n" .. fence .. "lua\r\nlocal value = 1\r\n" .. fence
    local app = open(text, 60)
    local selected = select_text(app, "界é")[1]
    assert.equal(text:find("界é", 1, true) - 1, selected.start_byte)
    assert.equal(selected.start_byte + #"界é", selected.end_byte)
    local code = select_text(app, "local value")[1]
    assert.equal(text:find("local value", 1, true) - 1, code.start_byte)
  end)

  it("applies document offsets to mapped fragments and preserves table-cell provenance", function()
    local text = "prefix: | left | right |\n| --- | --- |\n| first | **chosen** |"
    local function Doc()
      return { comp = ui.markdown, props = { text = text:sub(9),
        source = { id = "offset", text = text, offset = 8 } } }
    end
    local app = mount.floating(Doc, {}, { width = 50, height = 20, mode = "scroll" })
    apps[#apps + 1] = app
    local selected = select_text(app, "chosen")[1]
    assert.equal(text:find("chosen", 1, true) - 1, selected.start_byte)
    assert.equal(selected.start_byte + #"chosen", selected.end_byte)
  end)

  it("does not register stale sources after a mount is destroyed", function()
    local app = open("gone")
    local found = select_text(app, "gone")[1]
    app.unmount()
    assert.same({}, require("fibrous.sources").project("doc", found.start_byte, found.end_byte))
  end)
end)
