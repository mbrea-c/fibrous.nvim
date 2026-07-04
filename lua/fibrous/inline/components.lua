-- Inline component primitives (tracker "NEW UI HOST" task 5). Everything
-- visible is a thin function component over the ONE `text` host leaf — the
-- reconciler and host know nothing new, and each component is just a props
-- mapping (unmodifiable inline content by construction; the host buffer is).
--
-- Styling lives in `props.style`, in the ONE node-level vocabulary:
-- `text_hl` = foreground, `hl` = background fill of the whole rect, plus
-- border/padding/margin and the `_hover`/`_focus` state overrides ("Style
-- rework"). Layout props (width, height, grow, align, justify, gap,
-- align_self) pass through untouched. The pre-style-table aliases (`hl` as
-- foreground, `bg`, `hover_hl`) are GONE — style.normalize errors on them.
--
-- Interactive components forward their handlers plus a `role` marker onto the
-- node props; the cursor-interaction hit-map (task 6) walks the laid-out tree
-- and reads exactly those.

local theme = require("fibrous.inline.theme")

local M = {}

-- Host primitives, re-exported so apps only import this module.
M.col = { __host = "col" }
M.row = { __host = "row" }
M.text = { __host = "text" }
M.text_input = { __host = "text_input" }
M.raw_buffer = { __host = "raw_buffer" }

-- Copy `props` and overlay the node-level keys (text, role, theme, …).
-- Styling passes through untouched as props.style.
---@param props table
---@param over table
---@return table
local function node_props(props, over)
  return vim.tbl_extend("force", {}, props, over)
end

-- `text` may be a rich-text span list ("Style rework" S4): bare strings or
-- { "chunk", hl = ... } tables, e.g. { "plain ", { "loud", hl = "Title" } }.

---@param _ table ctx (unused)
---@param props { text: string|Span[], hl?: string, bg?: string }
function M.label(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = false }) }
end

---@param _ table ctx (unused)
---@param props { text: string|Span[], hl?: string, bg?: string }
function M.paragraph(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = true }) }
end

-- Interactive components tag themselves with their theme.styles key (S5) —
-- the host seeds those defaults below the instance's own props; pass
-- `theme = false` to opt out, or another key to restyle.

---@param props table
---@param key string
---@return string|false
local function theme_key(props, key)
  return props.theme == nil and key or props.theme
end

-- The button chip's brackets come from its theme.styles border (a transparent
-- left/right border), NOT from the text — restyle them per instance with a
-- border prop, or drop them with `theme = false` for a bare label.
---@param _ table ctx (unused)
---@param props { label: string, on_press?: fun(), hl?: string, bg?: string, theme?: string|false }
function M.button(_, props)
  return {
    comp = M.text,
    props = node_props(props, {
      text = props.label or "",
      role = "button",
      theme = theme_key(props, "button"),
      -- Shrink-wrap by default so hover/activation hug the visible widget;
      -- pass align_self = "stretch" (or a width) for a full-width button.
      align_self = props.align_self or "start",
    }),
  }
end

---@param _ table ctx (unused)
---@param props { label: string, checked?: boolean, on_toggle?: fun(checked: boolean), marks?: { checked?: string|Span, unchecked?: string|Span }, hl?: string, bg?: string, theme?: string|false }
function M.checkbox(_, props)
  -- Marks are content, so they default from theme.marks (not theme.styles)
  -- and override key-wise via the `marks` prop — bare strings or spans.
  local defaults = theme.marks.checkbox
  local marks = props.marks or {}
  local mark = props.checked and (marks.checked or defaults.checked)
    or (marks.unchecked or defaults.unchecked)
  return {
    comp = M.text,
    props = node_props(props, {
      text = { mark, " " .. (props.label or "") },
      role = "checkbox",
      theme = theme_key(props, "checkbox"),
      align_self = props.align_self or "start",
    }),
  }
end

return M
