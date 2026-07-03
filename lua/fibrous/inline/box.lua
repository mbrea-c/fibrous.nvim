-- Box-model resolution for the inline host (tracker "NEW UI HOST"): margin,
-- padding and border, each configurable per side, CSS-style. This module only
-- normalizes the loose prop specs into fully numeric per-side tables — the
-- layout engine does arithmetic on the result, the renderer draws the chars.

local theme = require("fibrous.inline.theme")

local M = {}

---@class Sides
---@field top integer
---@field right integer
---@field bottom integer
---@field left integer

---@alias SidesSpec nil|integer|{ top?: integer, right?: integer, bottom?: integer, left?: integer, x?: integer, y?: integer }

-- Normalize a margin/padding spec: nil → zeros, a number → all sides, a table
-- with optional x/y shorthands (horizontal/vertical pairs) and per-side keys;
-- an explicit side always wins over its shorthand.
---@param spec SidesSpec
---@return Sides
function M.sides(spec)
  if spec == nil then
    return { top = 0, right = 0, bottom = 0, left = 0 }
  end
  if type(spec) == "number" then
    return { top = spec, right = spec, bottom = spec, left = spec }
  end
  local x = spec.x or 0
  local y = spec.y or 0
  return {
    top = spec.top or y,
    right = spec.right or x,
    bottom = spec.bottom or y,
    left = spec.left or x,
  }
end

-- Border char sets. `top/right/bottom/left` are the edge chars, `tl/tr/br/bl`
-- the corners (drawn only where both adjacent sides are present).
local PRESETS = {
  single = { top = "─", right = "│", bottom = "─", left = "│", tl = "┌", tr = "┐", br = "┘", bl = "└" },
  rounded = { top = "─", right = "│", bottom = "─", left = "│", tl = "╭", tr = "╮", br = "╯", bl = "╰" },
  double = { top = "═", right = "║", bottom = "═", left = "║", tl = "╔", tr = "╗", br = "╝", bl = "╚" },
}

local SIDE_KEYS = { "top", "right", "bottom", "left" }
local CORNER_KEYS = { "tl", "tr", "br", "bl" }

---@class BorderTitle
---@field text string
---@field hl string            highlight for the title cells (default FibrousTitle)
---@field align "left"|"center"|"right"
---@field pos "top"|"bottom"

---@class Border
---@field sides Sides          per-side thickness (0 or 1)
---@field chars table<string, string>   edge + corner chars for the enabled sides
---@field hl string|nil        highlight group for the border cells
---@field title BorderTitle|nil  painted over the pos edge by the renderer

local TITLE_ALIGNS = { left = true, center = true, right = true }
local TITLE_POS = { top = true, bottom = true }

-- Normalize a title spec (a bare string is sugar for { text = ... }).
---@param spec string|{ text: string, hl?: string, align?: string, pos?: string }
---@return BorderTitle
local function title(spec)
  if type(spec) == "string" then
    spec = { text = spec }
  end
  if type(spec.text) ~= "string" then
    error("fibrous: border title needs a `text` string")
  end
  local align = spec.align or "left"
  if not TITLE_ALIGNS[align] then
    error("fibrous: invalid border title align '" .. tostring(align) .. "'")
  end
  local pos = spec.pos or "top"
  if not TITLE_POS[pos] then
    error("fibrous: invalid border title pos '" .. tostring(pos) .. "'")
  end
  return { text = spec.text, hl = spec.hl or "FibrousTitle", align = align, pos = pos }
end

---@alias BorderSpec nil|boolean|string|{ [1]?: string, top?: boolean|string, right?: boolean|string, bottom?: boolean|string, left?: boolean|string, corners?: table<string, string>, hl?: string, title?: string|table }

-- Normalize a border spec: nil/false → none; true → the themed default
-- preset (theme.border_preset) on all sides, a preset name → that preset. A
-- table names the sides to enable, each either `true` (preset char) or a
-- custom char, with optional custom `corners`, `hl` and `title`; naming a
-- preset as its first array element ({ "rounded", ... }) starts from that
-- preset on all sides, side keys then opting out (= false) or overriding the
-- char — without one, side/corner chars come from the themed preset.
---@param spec BorderSpec
---@return Border
function M.border(spec)
  local border = { sides = { top = 0, right = 0, bottom = 0, left = 0 }, chars = {}, hl = nil }
  if spec == nil or spec == false then
    return border
  end

  if spec == true then
    spec = theme.border_preset
  end
  if type(spec) == "string" then
    local preset = PRESETS[spec]
    if not preset then
      error("fibrous: unknown border preset '" .. spec .. "'")
    end
    border.sides = { top = 1, right = 1, bottom = 1, left = 1 }
    border.chars = vim.deepcopy(preset)
    return border
  end

  local preset, default_on = PRESETS[theme.border_preset], false
  if spec[1] then
    preset = PRESETS[spec[1]]
    if not preset then
      error("fibrous: unknown border preset '" .. tostring(spec[1]) .. "'")
    end
    default_on = true
  end
  for _, side in ipairs(SIDE_KEYS) do
    local v = spec[side]
    if v == nil then
      v = default_on
    end
    if v then
      border.sides[side] = 1
      border.chars[side] = v == true and preset[side] or v
    end
  end
  for _, corner in ipairs(CORNER_KEYS) do
    border.chars[corner] = (spec.corners and spec.corners[corner]) or preset[corner]
  end
  border.hl = spec.hl
  border.title = spec.title ~= nil and title(spec.title) or nil
  return border
end

---@class ResolvedBox
---@field margin Sides
---@field padding Sides
---@field border Border

-- Resolve a node's box-model props in one shot.
---@param props { margin?: SidesSpec, padding?: SidesSpec, border?: BorderSpec }
---@return ResolvedBox
function M.resolve(props)
  return {
    margin = M.sides(props.margin),
    padding = M.sides(props.padding),
    border = M.border(props.border),
  }
end

-- Inner edges: border + padding — what shrinks the content box within the
-- border box. Outer edges add margin on top — the content → margin-box delta.

---@param r ResolvedBox
---@return integer
function M.h_inner(r)
  return r.border.sides.left + r.padding.left + r.border.sides.right + r.padding.right
end

---@param r ResolvedBox
---@return integer
function M.v_inner(r)
  return r.border.sides.top + r.padding.top + r.border.sides.bottom + r.padding.bottom
end

---@param r ResolvedBox
---@return integer
function M.h_outer(r)
  return M.h_inner(r) + r.margin.left + r.margin.right
end

---@param r ResolvedBox
---@return integer
function M.v_outer(r)
  return M.v_inner(r) + r.margin.top + r.margin.bottom
end

return M
