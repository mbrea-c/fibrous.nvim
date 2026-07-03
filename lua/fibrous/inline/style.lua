-- Style resolution for the inline host (tracker "Style rework"). Pure, like
-- box.lua: no Neovim UI involved, so state-based styling is testable and
-- resolvable OUTSIDE the render cycle — a hover/focus change never re-runs
-- components or the reconciler, it just re-applies the committed style.
--
-- Two phases:
--   normalize(props, defaults)  once per commit, per node (defaults = the
--                               node's theme.styles entry, lowest precedence)
--   apply(norm, states)         at paint time, per interaction-state change
--
-- The style key set is closed (unknown keys error): `hl` (background fill of
-- the border box), `text_hl` (foreground), `border_hl` (border recolor —
-- wins over the border spec's own hl, and stays on the hl-only fast path),
-- `border` / `padding` / `margin` (box specs, normalized via box.lua).
-- State overrides live under `_hover` / `_focus` and merge onto the base
-- key-wise, each key replaced atomically (an overriding border spec swaps
-- the whole border; recolor-only wants `border_hl`).

local box = require("fibrous.inline.box")

local M = {}

-- hl-tier keys: overriding only these needs no relayout/repaint (extmark
-- overlay); the box keys are structural (relayout + repaint).
local HL_KEYS = { hl = true, text_hl = true, border_hl = true }
local BOX_KEYS = { border = true, padding = true, margin = true }

-- style-table state key → field on the normalized result
local STATE_KEYS = { _hover = "hover", _focus = "focus" }

---@class StylePartial
---@field hl string|nil
---@field text_hl string|nil
---@field border_hl string|nil
---@field border Border|nil
---@field padding Sides|nil
---@field margin Sides|nil

---@class NormalizedStyle
---@field base StylePartial  fully populated box keys (never nil)
---@field hover StylePartial|nil
---@field focus StylePartial|nil

-- Resolve one level of a style table into `out`, erroring on unknown keys.
-- `where` names the level for the error message.
---@param spec table
---@param out StylePartial
---@param where string
local function resolve_level(spec, out, where)
  for k, v in pairs(spec) do
    if HL_KEYS[k] then
      out[k] = v
    elseif k == "border" then
      out.border = box.border(v)
    elseif k == "padding" or k == "margin" then
      out[k] = box.sides(v)
    elseif not ((where == "style" or where == "theme") and STATE_KEYS[k]) then
      error(("fibrous: unknown style key '%s' in %s"):format(k, where))
    end
  end
end

-- Resolve a full style-shaped table (base keys + `_hover`/`_focus`) onto a
-- NormalizedStyle, overlaying key-wise onto whatever is already there.
---@param spec table
---@param norm NormalizedStyle
---@param where "style"|"theme"
local function resolve_style(spec, norm, where)
  resolve_level(spec, norm.base, where)
  for key, field in pairs(STATE_KEYS) do
    if spec[key] ~= nil then
      local part = norm[field] or {}
      resolve_level(spec[key], part, key)
      norm[field] = part
    end
  end
end

-- Normalize a node's style, precedence lowest → highest: the theme defaults
-- (style-shaped, from theme.styles via the node's `theme` prop), the
-- flat-prop sugar (hl, text_hl, border, padding, margin, hover_hl), then
-- props.style (base + `_hover`/`_focus` overrides). Key-wise throughout.
---@param props table  node props (non-style keys are ignored)
---@param defaults table|nil  theme defaults to seed below everything
---@return NormalizedStyle
function M.normalize(props, defaults)
  local base = {}
  local norm = { base = base }
  if defaults then
    resolve_style(defaults, norm, "theme")
  end

  for _, k in ipairs({ "hl", "text_hl" }) do
    if props[k] ~= nil then
      base[k] = props[k]
    end
  end
  if props.border ~= nil then
    base.border = box.border(props.border)
  end
  if props.padding ~= nil then
    base.padding = box.sides(props.padding)
  end
  if props.margin ~= nil then
    base.margin = box.sides(props.margin)
  end
  -- Box keys are always fully populated — layout does arithmetic on them
  -- without nil checks.
  base.border = base.border or box.border(nil)
  base.padding = base.padding or box.sides(nil)
  base.margin = base.margin or box.sides(nil)

  if props.hover_hl then
    local part = norm.hover or {}
    part.hl = props.hover_hl
    norm.hover = part
  end

  local spec = props.style
  if spec ~= nil then
    if type(spec) ~= "table" then
      error("fibrous: props.style must be a table")
    end
    resolve_style(spec, norm, "style")
  end
  return norm
end

-- Classify a normalized partial by the keys it carries: nil/empty → nil
-- (nothing to apply), only hl keys → "hl" (extmark-overlay fast path), any
-- box key → "structural" (relayout + repaint).
---@param part StylePartial|nil
---@return "hl"|"structural"|nil
function M.tier(part)
  local tier = nil
  if part then
    for k in pairs(part) do
      if BOX_KEYS[k] then
        return "structural"
      end
      tier = "hl"
    end
  end
  return tier
end

-- Overlay the active states onto the base: precedence base ← _focus ←
-- _hover, later wins per key. Returns the resolved style plus the delta
-- tier: nil (no override key applied), "hl" (fast path) or "structural"
-- (relayout + repaint). The result shares subtables with `norm` — treat
-- both as immutable.
---@param norm NormalizedStyle
---@param states { hover?: boolean, focus?: boolean }|nil
---@return StylePartial resolved
---@return "hl"|"structural"|nil tier
function M.apply(norm, states)
  states = states or {}
  local out = {}
  for k, v in pairs(norm.base) do
    out[k] = v
  end
  local tier = nil
  local function overlay(part)
    if not part then
      return
    end
    for k, v in pairs(part) do
      out[k] = v
      if BOX_KEYS[k] then
        tier = "structural"
      elseif tier == nil then
        tier = "hl"
      end
    end
  end
  overlay(states.focus and norm.focus or nil)
  overlay(states.hover and norm.hover or nil)
  return out, tier
end

return M
