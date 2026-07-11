-- Style resolution for the inline host (tracker "Style rework"). Pure, like
-- box.lua: no Neovim UI involved, so state-based styling is testable and
-- resolvable OUTSIDE the render cycle — a hover/focus change never re-runs
-- components or the reconciler, it just re-applies the committed style.
--
-- Two phases:
--   normalize(props, defaults)  once per commit, per node (defaults = the
--                               node's theme.styles entry, lowest precedence;
--                               all styling lives in props.style — the old
--                               flat props error, see REMOVED below)
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

-- The flat style props (`hl`, `text_hl`, `border`, `padding`, `margin`,
-- `hover_hl`, plus the component-era `bg`) were migration sugar ("Style
-- rework": "remain during migration") and are REMOVED: props.style is the one
-- styling vocabulary (hl = background fill, text_hl = foreground, _hover/
-- _focus for states). They error loudly rather than silently doing nothing —
-- `hl` used to mean FOREGROUND on components but FILL everywhere else, and a
-- silently-ignored leftover would be that trap all over again. (Raw layout
-- trees are untouched: box.resolve still reads border/padding/margin off
-- props — that is the layout engine's input format, not the component API.)
local REMOVED = { "hl", "text_hl", "bg", "border", "padding", "margin", "hover_hl" }

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
-- (style-shaped, from theme.styles via the node's `theme` prop), then
-- props.style (base + `_hover`/`_focus` overrides). Key-wise throughout.
-- The removed flat props error loudly (see REMOVED above).
---@param props table  node props (non-style keys are ignored)
---@param defaults table|nil  theme defaults to seed below everything
---@return NormalizedStyle
function M.normalize(props, defaults)
  local base = {}
  local norm = { base = base }
  if defaults then
    resolve_style(defaults, norm, "theme")
  end

  for _, k in ipairs(REMOVED) do
    if props[k] ~= nil then
      error(
        ("fibrous: the flat `%s` prop was removed; use props.style (hl = fill, text_hl = foreground, _hover/_focus for states)"):format(
          k
        )
      )
    end
  end

  -- Box keys are always fully populated — layout does arithmetic on them
  -- without nil checks.
  base.border = base.border or box.border(nil)
  base.padding = base.padding or box.sides(nil)
  base.margin = base.margin or box.sides(nil)

  local spec = props.style
  if spec ~= nil then
    if type(spec) ~= "table" then
      error("fibrous: props.style must be a table")
    end
    resolve_style(spec, norm, "style")
  end
  return norm
end

-- Span styling is a STRICT SUBSET of the node vocabulary: a span has no box
-- (no border/padding/margin), so only the text-appearance key `text_hl` and a
-- `_hover` state override are meaningful. Everything a span can style is thus
-- always the hl-only tier (an extmark overlay, never a relayout). Background
-- fill behind a run is deferred: a run's `text_hl` group can carry its own bg
-- (that is how inline code renders), so a separate bg key is not needed yet.
---@class SpanStyle
---@field base { text_hl?: string }
---@field hover { text_hl?: string }|nil
local SPAN_KEYS = { text_hl = true }

---@param spec table
---@param out table
---@param where string
local function resolve_span_level(spec, out, where)
  for k, v in pairs(spec) do
    if SPAN_KEYS[k] then
      out[k] = v
    elseif not (where == "span" and k == "_hover") then
      error(("fibrous: unknown span style key '%s' in %s"):format(k, where))
    end
  end
end

-- Normalize a span's `style` (the restricted vocabulary above), or nil.
---@param spec table|nil
---@return SpanStyle|nil
function M.span_style(spec)
  if spec == nil then
    return nil
  end
  if type(spec) ~= "table" then
    error("fibrous: a span `style` must be a table")
  end
  local base = {}
  resolve_span_level(spec, base, "span")
  local out = { base = base }
  if spec._hover ~= nil then
    local hover = {}
    resolve_span_level(spec._hover, hover, "_hover")
    out.hover = hover
  end
  return out
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
