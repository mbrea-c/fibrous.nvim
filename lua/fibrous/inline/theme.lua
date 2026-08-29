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
-- colorscheme defines. These are FILLS: they own their background (a hovered
-- row, a button chip, a popup row) and are meant to stand out against the
-- surface. Override with a plain `:hi` / nvim_set_hl of the same name —
-- `apply()` never clobbers an existing definition.
M.groups = {
  FibrousHover = { link = "CursorLine" },
  FibrousDim = { link = "Comment" },
  FibrousButton = { link = "Pmenu" },
  FibrousButtonHover = { link = "PmenuSel" },
  FibrousCheckboxMark = { link = "Special" },
  -- overlay surfaces (ui.popup rows: the dropdown's option list)
  FibrousPopup = { link = "Pmenu" },
  FibrousPopupSel = { link = "PmenuSel" },
}

-- Foreground-only groups, derived from a source group with its BACKGROUND
-- dropped. fibrous borders and titles are PAINTED — box-drawing text in the
-- host's own buffer, never nvim's native float border — so they sit directly
-- on whatever surface is behind them and must contribute a colour, not a fill.
-- The natural sources carry a bg of their own (LineNr the gutter's, FloatTitle
-- the float's), and a plain link would stamp that bg into every border cell:
-- on a buffer mount, whose Normal is the window's, that paints a darker
-- NormalFloat-looking rectangle around each box. A link cannot strip a key, so
-- these resolve the source and drop bg/ctermbg — same technique (and same
-- tradeoff) as FibrousMathVariable below: a derivation is a snapshot, not a
-- live link. `default = true` means an explicit user definition wins outright,
-- and ALSO that a derivation, once set, stays until the group is cleared — so
-- the snapshot refreshes on ColorScheme (schemes `hi clear` first, and the
-- autocmd re-derives from the new source), but a hand-rolled `:hi LineNr`
-- mid-session will not reach an already-derived FibrousBorder. That is the
-- price of stripping a key a link would carry.
--
-- LineNr: a subtle gray in dark AND light schemes. Directory for focus: the
-- focused state needs an actual accent COLOR — bold-only groups (CursorLineNr
-- in the stock scheme) are invisible on box-drawing glyphs, whose fonts rarely
-- have bold variants.
M.fg_groups = {
  FibrousBorder = "LineNr",
  FibrousBorderFocus = "Directory",
  FibrousTitle = "FloatTitle",
  -- ui.code / ui.diff line-number gutters: LineNr's colour without its bg —
  -- the gutter sits on whatever surface the snippet renders into, and
  -- stamping the sign-column bg there would draw a phantom sign column.
  FibrousCodeGutter = "LineNr",
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
  -- the select field: reads as `[▾value ]`, one line tall. The right bracket
  -- is a border; the left bracket + chevron are CONTENT (marks.dropdown.arrow
  -- below — the chevron is what tells a dropdown apart from a button chip, so
  -- it can't be a 1-cell border char). Both sit dim at rest and take the
  -- border focus accent while the field has the cursor — THE visible cue
  -- that the dropdown is focused (its float carries no fill to brighten).
  dropdown = {
    border = { right = "]", hl = "FibrousDim" },
    _focus = { border_hl = "FibrousBorderFocus" },
  },
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
  -- the dropdown field's left edge (see styles.dropdown): the component
  -- swaps the hl for the focus accent while the field has the cursor.
  dropdown = {
    arrow = { "[▾", hl = "FibrousDim" },
  },
}

-- FibrousMathVariable is the ONE computed group: ui.markdown italicises math
-- variables with it, but it must keep the user's @markup.math colour (which the
-- user owns, and which covers the rest of the equation), so it is derived as
-- "@markup.math resolved + italic" rather than a static link. `default` so an
-- explicit user definition still wins; recomputed in apply() to track scheme
-- and @markup.math changes across a ColorScheme switch.
local function apply_math_variable()
  local base = vim.api.nvim_get_hl(0, { name = "@markup.math", link = false })
  base.link = nil
  base.default = true
  base.italic = true
  base.cterm = vim.tbl_extend("force", base.cterm or {}, { italic = true })
  -- fg-only, like the border derivations: the snapshot must not stamp
  -- @markup.math's background into every variable cell — a math run sits on
  -- whatever surface is behind it (hlmix composes a fill's bg back in where
  -- one exists; everywhere else the surface's own background should show).
  base.bg = nil
  base.ctermbg = nil
  vim.api.nvim_set_hl(0, "FibrousMathVariable", base)
end

-- `source` resolved, background dropped: see M.fg_groups.
local function apply_fg_only(name, source)
  local base = vim.api.nvim_get_hl(0, { name = source, link = false })
  base.link = nil
  base.bg = nil
  base.ctermbg = nil
  base.default = true
  vim.api.nvim_set_hl(0, name, base)
end

-- Define the groups (without overriding existing definitions) and keep them
-- alive across colorscheme switches. Idempotent; host.new() calls this.
function M.apply()
  for name, spec in pairs(M.groups) do
    local def = vim.tbl_extend("force", { default = true }, spec)
    vim.api.nvim_set_hl(0, name, def)
  end
  for name, source in pairs(M.fg_groups) do
    apply_fg_only(name, source)
  end
  apply_math_variable()
  local group = vim.api.nvim_create_augroup("FibrousTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply })
end

return M
