-- Inline component primitives (tracker "NEW UI HOST" task 5). Everything
-- visible is a thin function component over the ONE `text` host leaf — the
-- reconciler and host know nothing new, and each component is just a props
-- mapping (unmodifiable inline content by construction; the host buffer is).
--
-- Public prop surface, mapped onto the node props render.lua understands:
--   hl  →  text_hl  (foreground of the text)
--   bg  →  hl       (background fill of the whole rect)
--   box/layout props (border, margin, padding, width, height, grow, align,
--   justify, gap) pass through untouched.
--
-- Interactive components forward their handlers plus a `role` marker onto the
-- node props; the cursor-interaction hit-map (task 6) walks the laid-out tree
-- and reads exactly those.

local M = {}

-- Host primitives, re-exported so apps only import this module.
M.col = { __host = "col" }
M.row = { __host = "row" }
M.text = { __host = "text" }
M.text_input = { __host = "text_input" }
M.raw_buffer = { __host = "raw_buffer" }

-- Copy `props` and overlay the node-level keys, translating hl/bg.
---@param props table
---@param over table
---@return table
local function node_props(props, over)
  local out = vim.tbl_extend("force", {}, props, over)
  out.text_hl = props.hl
  out.hl = props.bg
  out.bg = nil
  return out
end

---@param _ table ctx (unused)
---@param props { text: string, hl?: string, bg?: string }
function M.label(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = false }) }
end

---@param _ table ctx (unused)
---@param props { text: string, hl?: string, bg?: string }
function M.paragraph(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = true }) }
end

---@param _ table ctx (unused)
---@param props { label: string, on_press?: fun(), hl?: string, bg?: string }
function M.button(_, props)
  return {
    comp = M.text,
    props = node_props(props, {
      text = "[ " .. (props.label or "") .. " ]",
      role = "button",
      -- Shrink-wrap by default so hover/activation hug the visible widget;
      -- pass align_self = "stretch" (or a width) for a full-width button.
      align_self = props.align_self or "start",
    }),
  }
end

---@param _ table ctx (unused)
---@param props { label: string, checked?: boolean, on_toggle?: fun(checked: boolean), hl?: string, bg?: string }
function M.checkbox(_, props)
  return {
    comp = M.text,
    props = node_props(props, {
      text = (props.checked and "[x] " or "[ ] ") .. (props.label or ""),
      role = "checkbox",
      align_self = props.align_self or "start",
    }),
  }
end

return M
