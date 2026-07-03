-- The default theme (tracker "Style rework" S5): ONE module owning every
-- default — the Fibrous* highlight groups (defined as `default = true` links
-- so colorschemes and users override freely), the style-shaped defaults that
-- a node's `theme` prop keys into, and the border preset `border = true`
-- means.

local theme = require("fibrous.inline.theme")

local function link_of(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true }).link
end

describe("inline.theme", function()
  it("apply defines the Fibrous* groups as links", function()
    theme.apply()
    assert.equal("FloatBorder", link_of("FibrousBorder"))
    assert.equal("FloatTitle", link_of("FibrousTitle"))
    assert.equal("CursorLine", link_of("FibrousHover"))
    assert.equal("Comment", link_of("FibrousDim"))
    assert.equal("Pmenu", link_of("FibrousButton"))
    assert.equal("PmenuSel", link_of("FibrousButtonHover"))
    assert.equal("Special", link_of("FibrousCheckboxMark"))
  end)

  it("names the default border preset", function()
    assert.equal("rounded", theme.border_preset)
  end)

  it("carries style-shaped defaults per theme key", function()
    assert.equal("FibrousButton", theme.styles.button.hl)
    assert.equal("FibrousButtonHover", theme.styles.button._hover.hl)
    assert.equal("FibrousHover", theme.styles.checkbox._hover.hl)
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
