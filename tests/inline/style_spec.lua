-- Style resolution for the inline host (tracker "Style rework" S1). Pure
-- module, no Neovim UI involved:
--   normalize(props, defaults) — once at commit time: props.style (base keys
--     + `_hover`/`_focus` state overrides) over the theme defaults → fully
--     resolved base + per-state partials. Unknown style keys error loudly
--     (closed key set), and so do the REMOVED flat props (hl, text_hl, bg,
--     border, padding, margin, hover_hl) — styling has exactly one home.
--   apply(norm, states) — at paint time: overlay the active states onto the
--     base (precedence base ← _focus ← _hover, later wins per key, each key
--     replaced atomically) and report the delta tier: nil (no override
--     applied), "hl" (hl/text_hl/border_hl only → extmark fast path) or
--     "structural" (border/padding/margin → relayout + repaint).
--
-- Style keys are node-level: `hl` = background fill, `text_hl` = foreground,
-- `border_hl` = border recolor that wins over the border spec's own hl.

local style = require("fibrous.inline.style")

local ZERO = { top = 0, right = 0, bottom = 0, left = 0 }

describe("inline.style normalize", function()
  it("resolves the style-table keys onto the base", function()
    local norm = style.normalize({
      style = {
        hl = "Bg",
        text_hl = "Fg",
        border = "rounded",
        padding = 1,
        margin = { x = 2 },
      },
    })
    assert.equal("Bg", norm.base.hl)
    assert.equal("Fg", norm.base.text_hl)
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, norm.base.border.sides)
    assert.equal("╭", norm.base.border.chars.tl)
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, norm.base.padding)
    assert.same({ top = 0, right = 2, bottom = 0, left = 2 }, norm.base.margin)
  end)

  it("no style resolves to an all-zero box and no state partials", function()
    local norm = style.normalize({ text = "hi", role = "button" }) -- non-style props ignored
    assert.same(ZERO, norm.base.padding)
    assert.same(ZERO, norm.base.margin)
    assert.same(ZERO, norm.base.border.sides)
    assert.is_nil(norm.base.hl)
    assert.is_nil(norm.hover)
    assert.is_nil(norm.focus)
  end)

  it("the removed flat style props error loudly", function()
    for _, k in ipairs({ "hl", "text_hl", "bg", "border", "padding", "margin", "hover_hl" }) do
      assert.has_error(function()
        style.normalize({ [k] = "X" })
      end, k)
    end
  end)

  it("state overrides are resolved per key (box specs normalized)", function()
    local norm = style.normalize({
      style = {
        hl = "Normal",
        _hover = { hl = "Visual", border = "double" },
        _focus = { border_hl = "Title", padding = 2 },
      },
    })
    assert.equal("Visual", norm.hover.hl)
    assert.equal("═", norm.hover.border.chars.top)
    assert.equal("Title", norm.focus.border_hl)
    assert.same({ top = 2, right = 2, bottom = 2, left = 2 }, norm.focus.padding)
    -- partials carry ONLY the keys the override mentions
    assert.is_nil(norm.hover.padding)
    assert.is_nil(norm.focus.hl)
  end)

  it("theme defaults seed below the style table, key-wise", function()
    local norm = style.normalize(
      { style = { hl = "FromStyle" } },
      { hl = "FromTheme", text_hl = "ThemeText", _hover = { hl = "ThemeHover" } }
    )
    assert.equal("FromStyle", norm.base.hl)
    assert.equal("ThemeText", norm.base.text_hl)
    assert.equal("ThemeHover", norm.hover.hl)
  end)

  it("style._hover overrides a theme _hover key-wise", function()
    local norm = style.normalize(
      { style = { _hover = { hl = "Mine" } } },
      { _hover = { hl = "ThemeHover", text_hl = "ThemeHoverText" } }
    )
    assert.equal("Mine", norm.hover.hl)
    -- key-wise: theme hover keys the style doesn't touch survive
    assert.equal("ThemeHoverText", norm.hover.text_hl)
  end)

  it("theme box defaults resolve; explicit style keys replace them atomically", function()
    local themed = style.normalize({}, { border = "double", padding = 1 })
    assert.equal("═", themed.base.border.chars.top)
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, themed.base.padding)

    local off = style.normalize({ style = { border = false } }, { border = "double" })
    assert.same(ZERO, off.base.border.sides)
  end)

  it("unknown theme default keys error loudly", function()
    assert.has_error(function()
      style.normalize({}, { colour = "x" })
    end, "colour")
  end)

  it("unknown style keys error loudly, at the base and inside states", function()
    assert.has_error(function()
      style.normalize({ style = { colour = "x" } })
    end, "colour")
    assert.has_error(function()
      style.normalize({ style = { _hover = { hover_hl = "x" } } })
    end, "hover_hl")
    assert.has_error(function()
      style.normalize({ style = { _hover = { _focus = { hl = "x" } } } })
    end, "_focus")
  end)
end)

describe("inline.style tier", function()
  it("classifies a normalized partial by its keys", function()
    assert.is_nil(style.tier(nil))
    assert.is_nil(style.tier({}))
    assert.equal("hl", style.tier({ hl = "X", text_hl = "Y", border_hl = "Z" }))
    local norm = style.normalize({ style = { _hover = { hl = "X", padding = 1 } } })
    assert.equal("structural", style.tier(norm.hover))
  end)
end)

describe("inline.style apply", function()
  local norm = style.normalize({
    style = {
      hl = "Base",
      text_hl = "BaseText",
      border = "single",
      _hover = { hl = "HoverBg", text_hl = "HoverText" },
      _focus = { hl = "FocusBg", border_hl = "FocusBorder" },
    },
  })

  it("no active states returns the base, tier nil", function()
    local resolved, tier = style.apply(norm, {})
    assert.equal("Base", resolved.hl)
    assert.equal("BaseText", resolved.text_hl)
    assert.is_nil(tier)
  end)

  it("an active state without an override is tier nil", function()
    local plain = style.normalize({ style = { hl = "OnlyBase" } })
    local resolved, tier = style.apply(plain, { hover = true })
    assert.equal("OnlyBase", resolved.hl)
    assert.is_nil(tier)
  end)

  it("hover overlays the base key-wise, hl-only tier", function()
    local resolved, tier = style.apply(norm, { hover = true })
    assert.equal("HoverBg", resolved.hl)
    assert.equal("HoverText", resolved.text_hl)
    -- untouched base keys survive the overlay
    assert.same({ top = 1, right = 1, bottom = 1, left = 1 }, resolved.border.sides)
    assert.equal("hl", tier)
  end)

  it("precedence base ← _focus ← _hover: hover wins conflicts, focus-only keys apply", function()
    local resolved = style.apply(norm, { hover = true, focus = true })
    assert.equal("HoverBg", resolved.hl) -- both set hl → hover wins
    assert.equal("FocusBorder", resolved.border_hl) -- only focus sets it → applies
    assert.equal("HoverText", resolved.text_hl)
  end)

  it("border/padding/margin overrides are the structural tier", function()
    local structural = style.normalize({
      style = { border = "single", _hover = { hl = "V", border = "double" } },
    })
    local resolved, tier = style.apply(structural, { hover = true })
    assert.equal("structural", tier)
    -- atomic per-key replacement: the whole border spec is swapped, not merged
    assert.equal("═", resolved.border.chars.top)
    assert.equal("╔", resolved.border.chars.tl)
  end)

  it("does not mutate the normalized style", function()
    style.apply(norm, { hover = true, focus = true })
    assert.equal("Base", norm.base.hl)
    assert.is_nil(norm.base.border_hl)
    assert.equal("HoverBg", norm.hover.hl)
  end)
end)
