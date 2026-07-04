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

-- The incremental painter's container-descend: a container REBUILT because it
-- re-rendered (a list component committing a new entries array) but whose own
-- chrome — background, border — and child count are unchanged at the same
-- rect must not become a repaint root. It descends like a `_keep` node, so
-- its memoized children skip and only the truly changed child repaints. The
-- previous node rides along as `_prev` (host build_node stashes it); dirty
-- rows are the observable contract.
describe("inline.render update container-descend", function()
  local function entry(txt)
    return { kind = "text", props = {}, text = txt }
  end

  -- Simulate the host build's next frame: reuse `prev`'s children as memoized
  -- objects except position `swap`, which gets `fresh`.
  local function next_frame(prev, swap, fresh, props)
    local children = {}
    for i, child in ipairs(prev.children) do
      if i == swap then
        fresh._old_rect = child.rect
        children[i] = fresh
      else
        child._memo = true
        children[i] = child
      end
    end
    return {
      kind = "col",
      props = props or prev.props,
      children = children,
      _old_rect = prev.rect,
      _prev = prev,
    }
  end

  it("unchanged chrome at the same rect descends: only the changed child's rows are dirty", function()
    local t1 = { kind = "col", props = {}, children = { entry("aaa"), entry("bbb"), entry("ccc") } }
    layout.compute(t1, { width = 4 })
    local c = render.paint(t1, 4, t1.size.h)

    local t2 = next_frame(t1, 2, entry("BBB"))
    layout.compute(t2, { width = 4 })

    assert.same({ 1 }, render.update(c, t2))
    assert.same({ "aaa ", "BBB ", "ccc " }, c:lines())
  end)

  it("changed chrome stays a repaint root (and paints correctly)", function()
    local t1 = { kind = "col", props = {}, children = { entry("aaa"), entry("bbb") } }
    layout.compute(t1, { width = 4 })
    local c = render.paint(t1, 4, t1.size.h)

    local t2 = next_frame(t1, 2, entry("BBB"), { hl = "Visual" })
    layout.compute(t2, { width = 4 })

    assert.same({ 0, 1 }, render.update(c, t2))
    assert.same({ "aaa ", "BBB " }, c:lines())
    -- the new background reached every row, memoized child included
    local rows = {}
    for _, s in ipairs(c:highlights()) do
      if s.hl == "Visual" then
        rows[#rows + 1] = s.row
      end
    end
    assert.same({ 0, 1 }, rows)
  end)

  it("a lost trailing child forces the repaint root (vacated cells blanked)", function()
    -- fixed height: the container rect survives the removal, so only the
    -- child-count guard stands between the descend and stale bottom cells
    local t1 = { kind = "col", props = {}, children = { entry("aaa"), entry("bbb"), entry("ccc") } }
    layout.compute(t1, { width = 4, height = 3 })
    local c = render.paint(t1, 4, 3)

    local t2 = {
      kind = "col",
      props = t1.props,
      children = { t1.children[1], t1.children[2] },
      _old_rect = t1.rect,
      _prev = t1,
    }
    t1.children[1]._memo = true
    t1.children[2]._memo = true
    layout.compute(t2, { width = 4, height = 3 })

    render.update(c, t2)

    assert.same({ "aaa ", "bbb ", "    " }, c:lines())
  end)
end)

-- Growth: in scroll mode every append makes the frame taller, which used to
-- discard the canvas and repaint from scratch. With the canvas grown in place
-- (host calls Canvas:grow), a chrome-less container whose rect only gained
-- height — same x/y/w — descends: the old cells are all still right, the new
-- area is virgin canvas, and only the appended child paints.
describe("inline.render update growth-descend", function()
  local function entry(txt)
    return { kind = "text", props = {}, text = txt }
  end

  it("appending to a chrome-less container dirties only the new child's rows", function()
    local t1 = { kind = "col", props = {}, children = { entry("aaa"), entry("bbb") } }
    layout.compute(t1, { width = 4 })
    local c = render.paint(t1, 4, t1.size.h)

    for _, child in ipairs(t1.children) do
      child._memo = true
    end
    local t2 = {
      kind = "col",
      props = t1.props,
      children = { t1.children[1], t1.children[2], entry("ccc") },
      _old_rect = t1.rect,
      _prev = t1,
    }
    layout.compute(t2, { width = 4 })
    c:grow(t2.size.h)

    assert.same({ 2 }, render.update(c, t2))
    assert.same({ "aaa ", "bbb ", "ccc " }, c:lines())
  end)

  it("a bordered container that grows stays a repaint root (the edge moves)", function()
    local t1 = { kind = "col", props = { border = "single" }, children = { entry("aa") } }
    layout.compute(t1, { width = 4 })
    local c = render.paint(t1, 4, t1.size.h)

    t1.children[1]._memo = true
    local t2 = {
      kind = "col",
      props = t1.props,
      children = { t1.children[1], entry("bb") },
      _old_rect = t1.rect,
      _prev = t1,
    }
    layout.compute(t2, { width = 4 })
    c:grow(t2.size.h)

    render.update(c, t2)

    -- the bottom border sits under the new child, not stranded mid-box
    assert.same({ "┌──┐", "│aa│", "│bb│", "└──┘" }, c:lines())
  end)
end)
