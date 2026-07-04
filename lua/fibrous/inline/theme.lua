-- The default theme (tracker "Style rework" S5): the ONE module owning every
-- out-of-the-box default — highlight groups, per-component style defaults and
-- the default border preset. Nothing else in the library hardcodes a look.
--
--   groups         Fibrous* highlight groups, defined by `apply()` as
--                  `default = true` links: a colorscheme or user definition
--                  of the same group always wins. Re-applied on ColorScheme
--                  (a scheme switch clears unsaved links).
--   styles         style-shaped defaults (the `props.style` schema, `_hover`
--                  / `_focus` included) keyed by a node's `theme` prop, which
--                  defaults to the host tag (text_input, text, col, ...).
--                  Components tag themselves (button, checkbox); any node can
--                  opt in (`theme = "button"`) or out (`theme = false`).
--                  style.normalize seeds these at the LOWEST precedence —
--                  theme < flat props < props.style, key-wise.
--   marks          content defaults (mark spans) components splice into
--                  their text; overridden per instance by a `marks` prop.
--   border_preset  what `border = true` (and `side = true`) means.
--
-- This module must stay dependency-free within fibrous (box/style resolve the
-- raw specs later), so anything can require it without cycles.

local M = {}

-- Highlight groups, all namespaced Fibrous*, all links into groups every
-- colorscheme defines. Override with a plain `:hi` / nvim_set_hl of the same
-- name — `apply()` never clobbers an existing definition.
M.groups = {
  -- LineNr: a subtle gray in dark AND light schemes (FloatBorder usually
  -- just takes the float's normal fg). Directory for focus: the focused
  -- state needs an actual accent COLOR — bold-only groups (CursorLineNr in
  -- the stock scheme) are invisible on box-drawing glyphs, whose fonts
  -- rarely have bold variants.
  FibrousBorder = { link = "LineNr" },
  FibrousBorderFocus = { link = "Directory" },
  FibrousTitle = { link = "FloatTitle" },
  FibrousHover = { link = "CursorLine" },
  FibrousDim = { link = "Comment" },
  FibrousButton = { link = "Pmenu" },
  FibrousButtonHover = { link = "PmenuSel" },
  FibrousCheckboxMark = { link = "Special" },
}

-- The preset `border = true` resolves to (box.lua consults this).
M.border_preset = "rounded"

-- Style-shaped defaults per `theme` key. Add your own keys here (or replace
-- these) before mounting to restyle every instance at once.
M.styles = {
  -- a chip: the brackets are a transparent left/right BORDER (hl = false =
  -- inherit the fill), so they restyle per instance via the border prop and
  -- take the background + hover like any other cell; padding gives the
  -- breathing space "[ label ]" used to bake in. Same footprint as ever.
  button = {
    hl = "FibrousButton",
    border = { left = "[", right = "]", hl = false },
    padding = { x = 1 },
    _hover = { hl = "FibrousButtonHover" },
  },
  checkbox = { _hover = { hl = "FibrousHover" } },
  -- host primitives default their theme key to their own tag, so these
  -- apply to every text_input/raw_buffer: the border brightens while its
  -- float has the cursor (subwin.lua drives the focus state) — with the
  -- render="focus" default, that accent is what marks the edited widget
  raw_buffer = { _focus = { border_hl = "FibrousBorderFocus" } },
  text_input = { _focus = { border_hl = "FibrousBorderFocus" } },
}

-- Content defaults: mark spans components splice into their text. Not style
-- (marks are content, and the style key set stays closed) — per-instance
-- overrides go through the component's `marks` prop, key-wise.
M.marks = {
  checkbox = {
    checked = { "[x]", hl = "FibrousCheckboxMark" },
    unchecked = { "[ ]", hl = "FibrousDim" },
  },
}

-- Define the groups (without overriding existing definitions) and keep them
-- alive across colorscheme switches. Idempotent; host.new() calls this.
function M.apply()
  for name, spec in pairs(M.groups) do
    local def = vim.tbl_extend("force", { default = true }, spec)
    vim.api.nvim_set_hl(0, name, def)
  end
  local group = vim.api.nvim_create_augroup("FibrousTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply })
end

return M
