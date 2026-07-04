-- The pure two-pass layout engine (tracker "NEW UI HOST"): bottom-up
-- measure(max_width), top-down layout. `layout.compute(tree, { width, height })`
-- annotates every node with `size` (measured margin-box), `rect` (assigned
-- border-box) and `content` (rect inset by border+padding); text nodes also get
-- `lines`, their final display lines. height = nil is scroll mode (root height
-- = content height); a fixed height is app mode (grow/justify apply).

local layout = require("fibrous.inline.layout")

describe("inline.layout text nodes", function()
  it("nowrap text measures its widest line and line count", function()
    local tree = { kind = "text", text = "hello\nworld!!" }
    layout.compute(tree, { width = 40 })
    assert.same({ w = 7, h = 2 }, tree.size)
    assert.same({ "hello", "world!!" }, tree.lines)
  end)

  it("the root fills the given width and, in scroll mode, its content height", function()
    local tree = { kind = "text", text = "hi" }
    layout.compute(tree, { width = 40 })
    assert.same({ x = 0, y = 0, w = 40, h = 1 }, tree.rect)
  end)

  it("a fixed root height is applied as-is (app mode)", function()
    local tree = { kind = "text", text = "hi" }
    layout.compute(tree, { width = 40, height = 12 })
    assert.same({ x = 0, y = 0, w = 40, h = 12 }, tree.rect)
  end)

  it("wrap = true wraps at word boundaries to the available width", function()
    local tree = { kind = "text", props = { wrap = true }, text = "the quick brown fox jumps" }
    layout.compute(tree, { width = 10 })
    assert.same({ "the quick", "brown fox", "jumps" }, tree.lines)
    assert.equal(3, tree.size.h)
  end)

  it("wrapping preserves explicit newlines as paragraph breaks", function()
    local tree = { kind = "text", props = { wrap = true }, text = "aa bb\n\ncc dd" }
    layout.compute(tree, { width = 5 })
    assert.same({ "aa bb", "", "cc dd" }, tree.lines)
  end)

  it("words longer than the width are hard-broken", function()
    local tree = { kind = "text", props = { wrap = true }, text = "abcdefgh" }
    layout.compute(tree, { width = 3 })
    assert.same({ "abc", "def", "gh" }, tree.lines)
  end)

  it("assigned width narrower than measured re-wraps at layout time", function()
    -- A col child stretches to the col's content width; wrapped text must
    -- reflow to the width it actually got, not the width it was measured at.
    local text = { kind = "text", props = { wrap = true }, text = "aa bb cc" }
    local tree = {
      kind = "col",
      props = { padding = { x = 2 } },
      children = { text },
    }
    layout.compute(tree, { width = 9 })
    assert.same({ "aa bb", "cc" }, text.lines) -- 9 - 4 padding = 5 cols
  end)

  it("box edges shrink the content box and offset it inside the rect", function()
    local tree = {
      kind = "text",
      props = { wrap = true, margin = 1, border = true, padding = { x = 1 } },
      text = "aa bb cc",
    }
    layout.compute(tree, { width = 9 })
    -- 9 total - 2 margin - 2 border - 2 padding = 3 content cols
    assert.same({ "aa", "bb", "cc" }, tree.lines)
    -- margin-box measured: content(2..3 wide→uses 2? widest wrapped line is 2)
    -- rect: border-box, offset by margin
    assert.same({ x = 1, y = 1, w = 7, h = 5 }, tree.rect) -- 3 lines + border(2) = 5
    assert.same({ x = 3, y = 2, w = 3, h = 3 }, tree.content)
  end)
end)

describe("inline.layout rich-text spans", function()
  it("a span list measures as its concatenation", function()
    local tree = { kind = "text", text = { "hello ", { "world", hl = "Title" } } }
    layout.compute(tree, { width = 40 })
    assert.same({ w = 11, h = 1 }, tree.size)
    assert.same({ "hello world" }, tree.lines)
  end)

  it("nowrap span text splits at newlines, runs kept per line", function()
    local tree = { kind = "text", text = { { "a\nb", hl = "X" } } }
    layout.compute(tree, { width = 3 })
    assert.same({ "a", "b" }, tree.lines)
    assert.same({ { { text = "a", hl = "X" } }, { { text = "b", hl = "X" } } }, tree.line_runs)
  end)

  it("wrapping carries hl attribution through to per-line runs", function()
    local tree = { kind = "text", props = { wrap = true }, text = { "aa ", { "bb cc", hl = "Title" } } }
    layout.compute(tree, { width = 5 })
    assert.same({ "aa bb", "cc" }, tree.lines)
    assert.same({
      { { text = "aa " }, { text = "bb", hl = "Title" } },
      { { text = "cc", hl = "Title" } },
    }, tree.line_runs)
  end)
end)

describe("inline.layout border titles", function()
  it("a border title sets a min width: title + left/right border", function()
    local tree = {
      kind = "col",
      props = { align = "start" },
      children = {
        { kind = "text", props = { border = { "single", title = "Session" } }, text = "ab" },
      },
    }
    layout.compute(tree, { width = 20 })
    -- "Session" is 7 cells + 2 border columns = 9, wider than "ab" wants.
    assert.equal(9, tree.children[1].rect.w)
  end)

  it("an explicit width wins over the title min width", function()
    local tree = {
      kind = "col",
      props = { align = "start" },
      children = {
        { kind = "text", props = { width = 6, border = { "single", title = "Session" } }, text = "ab" },
      },
    }
    layout.compute(tree, { width = 20 })
    assert.equal(6, tree.children[1].rect.w)
  end)
end)

describe("inline.layout containers", function()
  it("col stacks children vertically; children stretch to the col width", function()
    local tree = {
      kind = "col",
      children = {
        { kind = "text", text = "aaa" },
        { kind = "text", text = "bb\ncc" },
      },
    }
    layout.compute(tree, { width = 10 })
    assert.same({ x = 0, y = 0, w = 10, h = 3 }, tree.rect) -- scroll mode: 1+2
    assert.same({ x = 0, y = 0, w = 10, h = 1 }, tree.children[1].rect)
    assert.same({ x = 0, y = 1, w = 10, h = 2 }, tree.children[2].rect)
  end)

  it("gap separates children along the main axis", function()
    local tree = {
      kind = "col",
      props = { gap = 1 },
      children = {
        { kind = "text", text = "a" },
        { kind = "text", text = "b" },
      },
    }
    layout.compute(tree, { width = 5 })
    assert.equal(3, tree.rect.h)
    assert.equal(0, tree.children[1].rect.y)
    assert.equal(2, tree.children[2].rect.y)
  end)

  it("container box edges offset the children", function()
    local tree = {
      kind = "col",
      props = { border = true, padding = { x = 1 } },
      children = {
        { kind = "text", text = "a" },
        { kind = "text", text = "b" },
      },
    }
    layout.compute(tree, { width = 10 })
    assert.same({ x = 0, y = 0, w = 10, h = 4 }, tree.rect) -- 2 lines + border 2
    assert.same({ x = 2, y = 1, w = 6, h = 1 }, tree.children[1].rect) -- inset border+padding
    assert.same({ x = 2, y = 2, w = 6, h = 1 }, tree.children[2].rect)
  end)

  it("align start/center/end position children on the cross axis", function()
    local function col_with(align)
      local tree = {
        kind = "col",
        props = { align = align },
        children = { { kind = "text", text = "aaa" } },
      }
      layout.compute(tree, { width = 11 })
      return tree.children[1].rect
    end
    assert.same({ x = 0, y = 0, w = 3, h = 1 }, col_with("start"))
    assert.same({ x = 4, y = 0, w = 3, h = 1 }, col_with("center"))
    assert.same({ x = 8, y = 0, w = 3, h = 1 }, col_with("end"))
  end)

  it("align_self overrides the container's cross-axis align per child", function()
    local tree = {
      kind = "col", -- default align = stretch
      children = {
        { kind = "text", text = "aaa", props = { align_self = "start" } },
        { kind = "text", text = "bbb" },
        { kind = "text", text = "ccc", props = { align_self = "center" } },
      },
    }
    layout.compute(tree, { width = 11 })
    assert.same({ x = 0, y = 0, w = 3, h = 1 }, tree.children[1].rect)
    assert.same({ x = 0, y = 1, w = 11, h = 1 }, tree.children[2].rect)
    assert.same({ x = 4, y = 2, w = 3, h = 1 }, tree.children[3].rect)
  end)

  it("align_self = stretch opts a child back in under a non-stretch container", function()
    local tree = {
      kind = "col",
      props = { align = "start" },
      children = {
        { kind = "text", text = "aaa", props = { align_self = "stretch" } },
        { kind = "text", text = "bbb" },
      },
    }
    layout.compute(tree, { width = 11 })
    assert.same({ x = 0, y = 0, w = 11, h = 1 }, tree.children[1].rect)
    assert.same({ x = 0, y = 1, w = 3, h = 1 }, tree.children[2].rect)
  end)

  it("row lays children left to right; row height is the tallest child", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "text", text = "aaa" },
        { kind = "text", text = "b\nb" },
      },
    }
    layout.compute(tree, { width = 20 })
    assert.same({ x = 0, y = 0, w = 20, h = 2 }, tree.rect)
    -- cross-axis stretch: both children get the row's full height
    assert.same({ x = 0, y = 0, w = 3, h = 2 }, tree.children[1].rect)
    assert.same({ x = 3, y = 0, w = 1, h = 2 }, tree.children[2].rect)
  end)

  it("grow children split the leftover main axis by weight (app mode)", function()
    local tree = {
      kind = "col",
      children = {
        { kind = "text", text = "a" },
        { kind = "col", props = { grow = 1 } },
        { kind = "col", props = { grow = 3 } },
      },
    }
    layout.compute(tree, { width = 10, height = 10 })
    -- leftover = 10 - 1 = 9; grow shares: floor(9/4)=2, remainder → last = 7
    assert.same({ x = 0, y = 0, w = 10, h = 1 }, tree.children[1].rect)
    assert.same({ x = 0, y = 1, w = 10, h = 2 }, tree.children[2].rect)
    assert.same({ x = 0, y = 3, w = 10, h = 7 }, tree.children[3].rect)
  end)

  it("grow works on the row main axis (spacer pattern)", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "text", text = "aaa" },
        { kind = "col", props = { grow = 1 } },
        { kind = "text", text = "bb" },
      },
    }
    layout.compute(tree, { width = 20 })
    assert.same({ x = 0, y = 0, w = 3, h = 1 }, tree.children[1].rect)
    assert.same({ x = 3, y = 0, w = 15, h = 1 }, tree.children[2].rect)
    assert.same({ x = 18, y = 0, w = 2, h = 1 }, tree.children[3].rect)
  end)

  it("in scroll mode vertical grow is inert (no leftover to take)", function()
    local tree = {
      kind = "col",
      children = {
        { kind = "text", text = "a" },
        { kind = "text", text = "b", props = { grow = 1 } },
      },
    }
    layout.compute(tree, { width = 5 })
    assert.equal(2, tree.rect.h)
    assert.same({ x = 0, y = 1, w = 5, h = 1 }, tree.children[2].rect)
  end)

  it("justify positions children along the main axis when nothing grows", function()
    local function col_with(justify)
      local tree = {
        kind = "col",
        props = { justify = justify },
        children = {
          { kind = "text", text = "a" },
          { kind = "text", text = "b" },
        },
      }
      layout.compute(tree, { width = 5, height = 8 })
      return tree.children[1].rect.y, tree.children[2].rect.y
    end
    local y1, y2 = col_with("start")
    assert.same({ 0, 1 }, { y1, y2 })
    y1, y2 = col_with("center") -- leftover 6 → offset 3
    assert.same({ 3, 4 }, { y1, y2 })
    y1, y2 = col_with("end")
    assert.same({ 6, 7 }, { y1, y2 })
    y1, y2 = col_with("space-between")
    assert.same({ 0, 7 }, { y1, y2 })
  end)

  it("max_width caps a grow child; the freed space goes to its siblings", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "col", props = { grow = 1, max_width = 6 } },
        { kind = "col", props = { grow = 1 } },
      },
    }
    layout.compute(tree, { width = 20 })
    assert.same({ x = 0, y = 0, w = 6, h = 0 }, tree.children[1].rect)
    assert.same({ x = 6, y = 0, w = 14, h = 0 }, tree.children[2].rect)
  end)

  it("min_width floors a grow child; the deficit comes out of its siblings", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "col", props = { grow = 3 } },
        { kind = "col", props = { grow = 1, min_width = 8 } },
      },
    }
    layout.compute(tree, { width = 20 })
    -- unclamped shares would be 15/5; the floor wins and the rest shrinks
    assert.same({ x = 0, y = 0, w = 12, h = 0 }, tree.children[1].rect)
    assert.same({ x = 12, y = 0, w = 8, h = 0 }, tree.children[2].rect)
  end)

  it("a min floor re-opens headroom under a sibling's max (freeze order)", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "col", props = { grow = 3, max_width = 15 } },
        { kind = "col", props = { grow = 1, min_width = 8 } },
      },
    }
    layout.compute(tree, { width = 20 })
    -- clamping both bounds against the 15/5 shares would overflow (15 + 8);
    -- freezing the min violation first re-shares 12 to the capped child
    assert.same({ x = 0, y = 0, w = 12, h = 0 }, tree.children[1].rect)
    assert.same({ x = 12, y = 0, w = 8, h = 0 }, tree.children[2].rect)
  end)

  it("min/max height clamp grow on the col main axis (app mode)", function()
    local tree = {
      kind = "col",
      children = {
        { kind = "col", props = { grow = 1, max_height = 3 } },
        { kind = "col", props = { grow = 1 } },
      },
    }
    layout.compute(tree, { width = 5, height = 10 })
    assert.same({ x = 0, y = 0, w = 5, h = 3 }, tree.children[1].rect)
    assert.same({ x = 0, y = 3, w = 5, h = 7 }, tree.children[2].rect)
  end)

  it("an explicit width pins the measuring constraint: children wrap at it", function()
    -- A fixed-width col late in a row must MEASURE its subtree at its own
    -- width, not at the row's remaining space (the sidebar-in-a-panel shape).
    -- The position pass only re-wraps col-STRETCHED text; inside a nested row
    -- children keep their measured size, so an over-wide measure is never
    -- corrected and paints clipped at the canvas edge.
    local text = { kind = "text", props = { wrap = true }, text = "aa bb cc dd" }
    local fixed = {
      kind = "col",
      props = { width = 8 },
      children = {
        {
          kind = "row",
          props = { gap = 1 },
          children = { { kind = "text", text = "*" }, text },
        },
      },
    }
    local tree = {
      kind = "row",
      children = {
        { kind = "col", props = { grow = 1 } },
        fixed,
      },
    }
    layout.compute(tree, { width = 30 })
    assert.same({ "aa bb", "cc dd" }, text.lines) -- wrapped at 8 - icon - gap = 6
    assert.equal(8, fixed.rect.w)
    assert.is_true(text.rect.x + text.rect.w <= 30)
  end)

  it("max_width caps cross-axis stretch and constrains the wrap width", function()
    local text = { kind = "text", props = { wrap = true, max_width = 5 }, text = "aa bb cc" }
    local tree = { kind = "col", children = { text } } -- default align = stretch
    layout.compute(tree, { width = 10 })
    assert.same({ "aa bb", "cc" }, text.lines)
    assert.same({ x = 0, y = 0, w = 5, h = 2 }, text.rect)
  end)

  it("min_width floors the measured size of a non-grow child", function()
    local tree = {
      kind = "row",
      children = {
        { kind = "text", text = "hi", props = { min_width = 6 } },
        { kind = "text", text = "b" },
      },
    }
    layout.compute(tree, { width = 20 })
    assert.same(6, tree.children[1].rect.w)
    assert.same(6, tree.children[2].rect.x)
  end)

  it("explicit width/height are border-box sizes and win over stretch", function()
    local fixed = { kind = "col", props = { width = 5, height = 3, border = true } }
    local tree = { kind = "col", children = { fixed } } -- default align = stretch
    layout.compute(tree, { width = 20 })
    assert.same({ x = 0, y = 0, w = 5, h = 3 }, fixed.rect)
    assert.same({ x = 1, y = 1, w = 3, h = 1 }, fixed.content) -- inset by border
  end)

  it("nested containers compose offsets", function()
    local tree = {
      kind = "col",
      children = {
        { kind = "text", text = "title" },
        {
          kind = "row",
          props = { gap = 1 },
          children = {
            { kind = "text", text = "x" },
            { kind = "text", text = "y" },
          },
        },
      },
    }
    layout.compute(tree, { width = 10 })
    local row = tree.children[2]
    assert.same({ x = 0, y = 1, w = 10, h = 1 }, row.rect)
    assert.same({ x = 0, y = 1, w = 1, h = 1 }, row.children[1].rect)
    assert.same({ x = 2, y = 1, w = 1, h = 1 }, row.children[2].rect)
  end)
end)
