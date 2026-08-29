-- ui.diff (fibrous.doc.diff): a unified diff with syntax highlighting UNDER
-- the Diff* line fills, a dual old│new line-number gutter, and folded context.
-- Built from before/after content (vim.diff) or a unified diff text.

local diff = require("fibrous.doc.diff")
local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function stub_ctx()
  return {
    use_ref = function(init)
      return { current = init }
    end,
  }
end

-- Compress build() output to "kind old:new" strings so expectations read
-- like the diff they describe.
local function shape(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.kind == "skip" then
      out[#out + 1] = "skip:" .. tostring(r.count)
    else
      out[#out + 1] = ("%s %s:%s"):format(r.kind, tostring(r.old_no), tostring(r.new_no))
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

describe("fibrous.doc.diff.build", function()
  it("interleaves a change with context and folds the far tail", function()
    local rows = diff.build({
      before = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
      after = "one\ntwo\nthree\nFOUR\nfive\nsix\nseven\neight",
    })
    assert.same({
      "ctx 1:1",
      "ctx 2:2",
      "ctx 3:3",
      "del 4:nil",
      "add nil:4",
      "ctx 5:5",
      "ctx 6:6",
      "ctx 7:7",
      "skip:1",
    }, shape(rows))
    -- the del row carries the OLD text, the add row the NEW
    assert.equal("four", rows[4].text)
    assert.equal("FOUR", rows[5].text)
  end)

  it("numbers an insertion: new-side numbers drift past the old", function()
    local rows = diff.build({ before = "a\nb", after = "a\nx\nb" })
    assert.same({ "ctx 1:1", "add nil:2", "ctx 2:3" }, shape(rows))
  end)

  it("numbers a deletion: old-side numbers drift past the new", function()
    local rows = diff.build({ before = "a\nx\nb", after = "a\nb" })
    assert.same({ "ctx 1:1", "del 2:nil", "ctx 3:2" }, shape(rows))
  end)

  it("folds the gap between far-apart hunks to context lines and a skip", function()
    local old_lines, new_lines = {}, {}
    for i = 1, 20 do
      old_lines[i] = "line " .. i
      new_lines[i] = "line " .. i
    end
    new_lines[3] = "LINE 3"
    new_lines[15] = "LINE 15"
    local rows = diff.build({
      before = table.concat(old_lines, "\n"),
      after = table.concat(new_lines, "\n"),
      context = 2,
    })
    assert.same({
      "ctx 1:1",
      "ctx 2:2",
      "del 3:nil",
      "add nil:3",
      "ctx 4:4",
      "ctx 5:5",
      "skip:7",
      "ctx 13:13",
      "ctx 14:14",
      "del 15:nil",
      "add nil:15",
      "ctx 16:16",
      "ctx 17:17",
      "skip:3",
    }, shape(rows))
  end)

  it("shifts both sides by start_line, so numbers match the referenced file", function()
    local rows = diff.build({ before = "a\nx\nb", after = "a\ny\nb", start_line = 40 })
    assert.same({ "ctx 40:40", "del 41:nil", "add nil:41", "ctx 42:42" }, shape(rows))
  end)

  it("returns no rows for identical sides", function()
    assert.same({}, diff.build({ before = "same\ntext", after = "same\ntext" }))
  end)

  it("parses a unified diff: hunk headers give absolute numbers", function()
    local rows = diff.build({
      unified = table.concat({
        "@@ -10,3 +12,4 @@",
        " ctx1",
        "-old1",
        "+new1",
        "+new2",
        " ctx2",
        "@@ -30,1 +33,1 @@",
        "-o",
        "+n",
      }, "\n"),
    })
    assert.same({
      "ctx 10:12",
      "del 11:nil",
      "add nil:13",
      "add nil:14",
      "ctx 12:15",
      "skip:nil",
      "del 30:nil",
      "add nil:33",
    }, shape(rows))
    assert.equal("old1", rows[2].text)
    assert.equal("new2", rows[4].text)
  end)

  it("ignores unified noise: git headers and no-newline markers", function()
    local rows = diff.build({
      unified = table.concat({
        "diff --git a/f.lua b/f.lua",
        "--- a/f.lua",
        "+++ b/f.lua",
        "@@ -1,1 +1,1 @@",
        "-a",
        "+b",
        "\\ No newline at end of file",
      }, "\n"),
    })
    assert.same({ "del 1:nil", "add nil:1" }, shape(rows))
  end)
end)

describe("fibrous.doc.diff.component", function()
  -- The tree is col{ header?, (row|skip-label)..., marker? }; a line row is
  -- row{ gutter-label, code-text }.
  local function line_rows(v)
    local out = {}
    for _, child in ipairs(v.children) do
      if child.comp == ui.row then
        out[#out + 1] = child
      end
    end
    return out
  end

  it("paints add/del rows with Diff fills and keeps syntax spans", function()
    local v = diff.component(stub_ctx(), {
      before = "local x = 1",
      after = "local x = 2",
      lang = "lua",
    })
    local rows = line_rows(v)
    assert.equal(2, #rows)
    local del, add = rows[1].children[2], rows[2].children[2]
    assert.equal("DiffDelete", del.props.style.hl)
    assert.equal("DiffAdd", add.props.style.hl)
    -- the fill is the BACKGROUND; the foreground is still syntax spans
    assert.equal("table", type(add.props.text))
    assert.equal("local x = 2", span_text(add.props.text))
  end)

  it("renders a dual gutter: old and new numbers, sign column", function()
    local v = diff.component(stub_ctx(), { before = "a\nx\nb", after = "a\ny\nb" })
    local rows = line_rows(v)
    local function gutter(i)
      return span_text(rows[i].children[1].props.text)
    end
    assert.equal("1 1   ", gutter(1))
    assert.equal("2   - ", gutter(2))
    assert.equal("  2 + ", gutter(3))
    assert.equal("3 3   ", gutter(4))
  end)

  it("drops the numbers with line_numbers = false, keeping the sign", function()
    local v = diff.component(stub_ctx(), { before = "a", after = "b", line_numbers = false })
    local rows = line_rows(v)
    assert.equal("- ", span_text(rows[1].children[1].props.text))
    assert.equal("+ ", span_text(rows[2].children[1].props.text))
  end)

  it("caps rendered rows at max_lines with a dim marker", function()
    local v = diff.component(stub_ctx(), {
      before = "a\nb\nc\nd",
      after = "w\nx\ny\nz",
      max_lines = 3,
    })
    assert.equal(3, #line_rows(v))
    local last = v.children[#v.children]
    assert.equal(ui.label, last.comp)
    assert.truthy(last.props.text:find("truncated", 1, true))
  end)

  it("says so when there is nothing to show", function()
    local v = diff.component(stub_ctx(), { before = "same", after = "same" })
    assert.equal(0, #line_rows(v))
    assert.truthy(v.children[1].props.text:find("no changes", 1, true))
  end)

  it("mounts through ui.diff with a clickable reference header", function()
    local function App()
      return {
        comp = ui.diff,
        props = {
          before = "local x = 1",
          after = "local x = 2",
          ref = { path = "foo.lua", start_line = 12 },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 40, height = 5 })
    local text = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("foo.lua:12", 1, true), "header shows the reference")
    assert.truthy(text:find("- local x = 1", 1, true))
    assert.truthy(text:find("+ local x = 2", 1, true))
    assert.truthy(text:find("12", 1, true), "numbers offset by start_line")
    handle.unmount()
  end)
end)
