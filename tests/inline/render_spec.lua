-- The tree painter (tracker "NEW UI HOST" task 2): takes a laid-out tree
-- (layout.compute annotations) and paints it onto a canvas — backgrounds,
-- per-side borders with corners, text clipped to its content box.

local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")

local function painted(tree, opts)
  layout.compute(tree, opts)
  return render.paint(tree, opts.width, opts.height or tree.size.h)
end

describe("inline.render", function()
  it("draws a full border with corners (themed default = rounded)", function()
    local tree = { kind = "text", props = { border = true }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "╭──╮", "│ab│", "╰──╯" }, c:lines())
  end)

  it("a named preset overrides the themed default", function()
    local tree = { kind = "text", props = { border = "single" }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "┌──┐", "│ab│", "└──┘" }, c:lines())
  end)

  it("left/right-only borders draw edges but no corners", function()
    local tree = { kind = "text", props = { border = { left = "│", right = "║" } }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "│ab║" }, c:lines())
  end)

  it("a corner appears only where both adjacent sides exist", function()
    local tree = { kind = "text", props = { border = { top = true, left = true } }, text = "ab" }
    local c = painted(tree, { width = 4 })
    -- tl corner, top edge to the end (no right side), left edge below
    assert.same({ "╭───", "│ab " }, c:lines())
  end)

  it("border cells carry the border hl (default FibrousBorder)", function()
    local tree = { kind = "text", props = { border = { left = true } }, text = "a" }
    local c = painted(tree, { width = 2 })
    assert.same({ { row = 0, start_col = 0, end_col = 3, hl = "FibrousBorder" } }, c:highlights())
  end)

  it("a transparent border (hl = false) inherits the node's background fill", function()
    local tree = { kind = "text", props = { hl = "Chip", border = { left = "[", right = "]", hl = false } }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "[ab]" }, c:lines())
    -- one uniform span: the bracket cells keep the hl_rect fill
    assert.same({ { row = 0, start_col = 0, end_col = 4, hl = "Chip" } }, c:highlights())
  end)

  it("a transparent border over no fill leaves its cells unhighlighted", function()
    local tree = { kind = "text", props = { border = { left = "[", right = "]", hl = false } }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "[ab]" }, c:lines())
    assert.same({}, c:highlights())
  end)

  it("props.hl fills the node's rect as background; text draws over it", function()
    local tree = { kind = "text", props = { hl = "Visual", padding = { x = 1 } }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ " ab " }, c:lines())
    assert.same({ { row = 0, start_col = 0, end_col = 4, hl = "Visual" } }, c:highlights())
  end)

  it("nowrap text wider than its content box is clipped", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "text", props = { width = 3 }, text = "abcdef" },
        { kind = "text", text = "z" },
      },
    }
    local c = painted(tree, { width = 5 })
    assert.same({ "abcz " }, c:lines())
  end)

  it("text taller than its content box is clipped", function()
    local tree = { kind = "text", props = { height = 2 }, text = "a\nb\nc\nd" }
    local c = painted(tree, { width = 3, height = 2 })
    assert.same({ "a  ", "b  " }, c:lines())
  end)

  it("span hls land as canvas highlight spans at their columns", function()
    local tree = { kind = "text", text = { "ab ", { "cd", hl = "Title" } } }
    local c = painted(tree, { width = 6 })
    assert.same({ "ab cd " }, c:lines())
    assert.same({ { row = 0, start_col = 3, end_col = 5, hl = "Title" } }, c:highlights())
  end)

  it("runs without their own hl fall back to the node text_hl", function()
    local tree = { kind = "text", props = { text_hl = "Comment" }, text = { "x", { "y", hl = "T" } } }
    local c = painted(tree, { width = 3 })
    assert.same({
      { row = 0, start_col = 0, end_col = 1, hl = "Comment" },
      { row = 0, start_col = 1, end_col = 2, hl = "T" },
    }, c:highlights())
  end)

  it("wrapped span hl follows the text across lines", function()
    local tree = { kind = "text", props = { wrap = true }, text = { "aa ", { "bb cc", hl = "Title" } } }
    local c = painted(tree, { width = 5 })
    assert.same({ "aa bb", "cc   " }, c:lines())
    assert.same({
      { row = 0, start_col = 3, end_col = 5, hl = "Title" },
      { row = 1, start_col = 0, end_col = 2, hl = "Title" },
    }, c:highlights())
  end)

  it("a border title paints over the top edge (align left)", function()
    local tree = { kind = "text", props = { border = { "single", title = "Hi" } }, text = "abcd" }
    local c = painted(tree, { width = 6 })
    assert.same({ "┌Hi──┐", "│abcd│", "└────┘" }, c:lines())
  end)

  it("title align center/right and pos bottom position on the edge", function()
    local centered = painted(
      { kind = "text", props = { border = { "single", title = { text = "Hi", align = "center" } } }, text = "abcd" },
      { width = 6 }
    )
    assert.same({ "┌─Hi─┐", "│abcd│", "└────┘" }, centered:lines())
    local bottom_right = painted({
      kind = "text",
      props = { border = { "single", title = { text = "Hi", align = "right", pos = "bottom" } } },
      text = "abcd",
    }, { width = 6 })
    assert.same({ "┌────┐", "│abcd│", "└──Hi┘" }, bottom_right:lines())
  end)

  it("title hl wins over the border hl for the title cells only", function()
    local tree = {
      kind = "text",
      props = { border = { "single", hl = "MyBorder", title = { text = "T", hl = "Title" } } },
      text = "a",
    }
    local c = painted(tree, { width = 3 })
    local title_spans, border_spans = 0, 0
    for _, s in ipairs(c:highlights()) do
      if s.hl == "Title" then
        title_spans = title_spans + 1
      elseif s.hl == "MyBorder" then
        border_spans = border_spans + 1
      end
    end
    assert.is_true(title_spans >= 1)
    assert.is_true(border_spans >= 1)
  end)

  it("a title longer than the edge span is cropped", function()
    local tree = {
      kind = "text",
      props = { width = 6, border = { "single", title = "Overlong" } },
      text = "abcd",
    }
    local c = painted(tree, { width = 6 })
    assert.same({ "┌Over┐", "│abcd│", "└────┘" }, c:lines())
  end)

  it("nested containers compose: borders, gap and children all land", function()
    local tree = {
      kind = "col",
      props = { border = true },
      children = {
        { kind = "text", text = "hi" },
        {
          kind = "row",
          props = { gap = 1 },
          children = {
            { kind = "text", text = "a" },
            { kind = "text", text = "b" },
          },
        },
      },
    }
    local c = painted(tree, { width = 6 })
    assert.same({
      "╭────╮",
      "│hi  │",
      "│a b │",
      "╰────╯",
    }, c:lines())
  end)
end)
