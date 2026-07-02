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
  it("draws a full border with corners", function()
    local tree = { kind = "text", props = { border = true }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "┌──┐", "│ab│", "└──┘" }, c:lines())
  end)

  it("rounded preset uses rounded corners", function()
    local tree = { kind = "text", props = { border = "rounded" }, text = "ab" }
    local c = painted(tree, { width = 4 })
    assert.same({ "╭──╮", "│ab│", "╰──╯" }, c:lines())
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
    assert.same({ "┌───", "│ab " }, c:lines())
  end)

  it("border cells carry the border hl (default FloatBorder)", function()
    local tree = { kind = "text", props = { border = { left = true } }, text = "a" }
    local c = painted(tree, { width = 2 })
    assert.same({ { row = 0, start_col = 0, end_col = 3, hl = "FloatBorder" } }, c:highlights())
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
      "┌────┐",
      "│hi  │",
      "│a b │",
      "└────┘",
    }, c:lines())
  end)
end)
