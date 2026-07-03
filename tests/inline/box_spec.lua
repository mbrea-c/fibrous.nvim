-- Box-model normalization (inline host, tracker "NEW UI HOST" §box model):
-- margin / padding / border, each configurable per side. `box.resolve` turns
-- the loose prop spec into a fully-populated numeric form the layout engine
-- can do arithmetic on without nil checks.

local box = require("fibrous.inline.box")

describe("inline.box sides", function()
  it("nil resolves to all zeros", function()
    assert.same({ top = 0, right = 0, bottom = 0, left = 0 }, box.sides(nil))
  end)

  it("a number applies to all four sides", function()
    assert.same({ top = 2, right = 2, bottom = 2, left = 2 }, box.sides(2))
  end)

  it("a partial table defaults missing sides to 0", function()
    assert.same({ top = 1, right = 0, bottom = 0, left = 3 }, box.sides({ top = 1, left = 3 }))
  end)

  it("x/y shorthands set horizontal/vertical pairs", function()
    assert.same({ top = 1, right = 2, bottom = 1, left = 2 }, box.sides({ x = 2, y = 1 }))
  end)

  it("an explicit side overrides its shorthand", function()
    assert.same({ top = 0, right = 2, bottom = 0, left = 0 }, box.sides({ x = 2, left = 0 }))
  end)
end)

describe("inline.box border", function()
  it("nil/false resolve to no border on any side", function()
    for _, spec in ipairs({ "nil", "false" }) do
      local b = box.border(spec == "nil" and nil or false)
      assert.same({ top = 0, right = 0, bottom = 0, left = 0 }, b.sides)
    end
  end)

  it("true is the themed default preset (rounded) on all sides", function()
    local b = box.border(true)
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, b.sides)
    assert.equal("─", b.chars.top)
    assert.equal("│", b.chars.left)
    assert.equal("╭", b.chars.tl)
    assert.equal("╯", b.chars.br)
  end)

  it("'rounded' preset uses rounded corners", function()
    local b = box.border("rounded")
    assert.equal("╭", b.chars.tl)
    assert.equal("╮", b.chars.tr)
    assert.equal("╯", b.chars.br)
    assert.equal("╰", b.chars.bl)
    assert.equal("─", b.chars.top)
  end)

  it("per-side spec enables only the named sides (left/right only)", function()
    local b = box.border({ left = "│", right = "║" })
    assert.same({ top = 0, right = 1, bottom = 0, left = 1 }, b.sides)
    assert.equal("│", b.chars.left)
    assert.equal("║", b.chars.right)
  end)

  it("side = true uses the themed preset's char for that side", function()
    local b = box.border({ top = true })
    assert.same({ top = 1, right = 0, bottom = 0, left = 0 }, b.sides)
    assert.equal("─", b.chars.top)
    assert.equal("╭", b.chars.tl) -- corners come from the themed preset too
  end)

  it("custom corners and hl pass through", function()
    local b = box.border({ top = true, left = true, corners = { tl = "+" }, hl = "MyBorder" })
    assert.equal("+", b.chars.tl)
    assert.equal("MyBorder", b.hl)
  end)

  it("hl = false marks the border transparent (kept distinct from nil)", function()
    local b = box.border({ left = "[", right = "]", hl = false })
    assert.is_false(b.hl)
  end)
end)

describe("inline.box border title", function()
  it("a positional preset name fills all sides; side keys override", function()
    local b = box.border({ "double" })
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, b.sides)
    assert.equal("═", b.chars.top)
    assert.equal("╔", b.chars.tl)
    local partial = box.border({ "rounded", bottom = false })
    assert.same({ top = 1, right = 1, bottom = 0, left = 1 }, partial.sides)
    assert.equal("╭", partial.chars.tl)
  end)

  it("title normalizes with defaults hl = FibrousTitle, align = left, pos = top", function()
    local b = box.border({ "rounded", title = { text = "Plan" } })
    assert.same({ text = "Plan", hl = "FibrousTitle", align = "left", pos = "top" }, b.title)
  end)

  it("a bare string is sugar for { text = ... }", function()
    local b = box.border({ "single", title = "Plan" })
    assert.same({ text = "Plan", hl = "FibrousTitle", align = "left", pos = "top" }, b.title)
  end)

  it("hl, align and pos pass through", function()
    local b = box.border({ "single", title = { text = "T", hl = "Title", align = "center", pos = "bottom" } })
    assert.same({ text = "T", hl = "Title", align = "center", pos = "bottom" }, b.title)
  end)

  it("invalid titles error loudly", function()
    assert.has_error(function()
      box.border({ "single", title = {} })
    end, "title")
    assert.has_error(function()
      box.border({ "single", title = { text = "T", align = "middle" } })
    end, "align")
    assert.has_error(function()
      box.border({ "single", title = { text = "T", pos = "left" } })
    end, "pos")
  end)
end)

describe("inline.box resolve", function()
  it("resolves margin, padding and border together with edge totals", function()
    local r = box.resolve({
      margin = 1,
      padding = { x = 2 },
      border = { left = "│", right = "│" },
    })
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, r.margin)
    assert.same({ top = 0, right = 2, bottom = 0, left = 2 }, r.padding)
    assert.same({ top = 0, right = 1, bottom = 0, left = 1 }, r.border.sides)
    -- inner edges = border + padding (what shrinks the content box)
    assert.equal(6, box.h_inner(r)) -- 1+2 left, 1+2 right
    assert.equal(0, box.v_inner(r))
    -- outer edges = margin + border + padding (content → margin-box delta)
    assert.equal(8, box.h_outer(r))
    assert.equal(2, box.v_outer(r))
  end)

  it("resolves absent props to all-zero edges", function()
    local r = box.resolve({})
    assert.equal(0, box.h_outer(r))
    assert.equal(0, box.v_outer(r))
  end)
end)
