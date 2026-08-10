-- The default theme (tracker "Style rework" S5): ONE module owning every
-- default — the Fibrous* highlight groups (all `default = true`, so
-- colorschemes and users override freely: fills as links, painted borders as
-- fg-only derivations), the style-shaped defaults that a node's `theme` prop
-- keys into, and the border preset `border = true` means.

local theme = require("fibrous.inline.theme")

local function link_of(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true }).link
end

local function resolve(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

describe("inline.theme", function()
  it("apply defines the fill groups as links", function()
    theme.apply()
    assert.equal("CursorLine", link_of("FibrousHover"))
    assert.equal("Comment", link_of("FibrousDim"))
    assert.equal("Pmenu", link_of("FibrousButton"))
    assert.equal("PmenuSel", link_of("FibrousButtonHover"))
    assert.equal("Special", link_of("FibrousCheckboxMark"))
  end)

  -- Borders and titles are PAINTED over the host surface, so they must take
  -- their source's COLOUR without its background — LineNr's gutter bg or
  -- FloatTitle's float bg would otherwise stamp a darker rectangle around
  -- every box on a buffer mount, whose Normal is the window's.
  it("apply derives the painted-border groups fg-only", function()
    vim.api.nvim_set_hl(0, "LineNr", { fg = "#888888", bg = "#111111" })
    vim.api.nvim_set_hl(0, "Directory", { fg = "#00ff00", bg = "#111111", bold = true })
    vim.api.nvim_set_hl(0, "FloatTitle", { fg = "#ffffff", bg = "#111111" })
    for name in pairs(theme.fg_groups) do
      vim.api.nvim_set_hl(0, name, {})
    end
    theme.apply()

    local border = resolve("FibrousBorder")
    assert.equal(tonumber("888888", 16), border.fg)
    assert.is_nil(border.bg)
    assert.is_nil(link_of("FibrousBorder"))

    local focus = resolve("FibrousBorderFocus")
    assert.equal(tonumber("00ff00", 16), focus.fg)
    assert.is_nil(focus.bg)
    assert.is_true(focus.bold)

    local title = resolve("FibrousTitle")
    assert.equal(tonumber("ffffff", 16), title.fg)
    assert.is_nil(title.bg)
  end)

  it("an existing painted-border definition wins over apply", function()
    vim.api.nvim_set_hl(0, "FibrousBorder", { fg = "#ff00ff" })
    theme.apply()
    assert.equal(tonumber("ff00ff", 16), resolve("FibrousBorder").fg)
    vim.api.nvim_set_hl(0, "FibrousBorder", {})
    theme.apply()
  end)

  it("names the default border preset", function()
    assert.equal("rounded", theme.border_preset)
  end)

  it("carries style-shaped defaults per theme key", function()
    assert.equal("FibrousButton", theme.styles.button.hl)
    assert.equal("FibrousButtonHover", theme.styles.button._hover.hl)
    assert.equal("FibrousHover", theme.styles.checkbox._hover.hl)
  end)

  it("text inputs get a focused-border accent", function()
    assert.equal("FibrousBorderFocus", theme.styles.text_input._focus.border_hl)
  end)

  it("the button chip is a transparent bracket border, not baked text", function()
    local b = theme.styles.button
    assert.same({ left = "[", right = "]", hl = false }, b.border)
    assert.same({ x = 1 }, b.padding)
  end)

  it("carries the checkbox mark spans (content defaults)", function()
    assert.same({ "[x]", hl = "FibrousCheckboxMark" }, theme.marks.checkbox.checked)
    assert.same({ "[ ]", hl = "FibrousDim" }, theme.marks.checkbox.unchecked)
  end)

  -- Last in the file: leaves FibrousDim as an explicit (non-default) link to
  -- its themed value, which no other assertion depends on.
  it("an existing user definition wins over apply", function()
    vim.api.nvim_set_hl(0, "FibrousDim", { link = "ErrorMsg" })
    theme.apply()
    assert.equal("ErrorMsg", link_of("FibrousDim"))
    vim.api.nvim_set_hl(0, "FibrousDim", { link = "Comment" })
  end)
end)
