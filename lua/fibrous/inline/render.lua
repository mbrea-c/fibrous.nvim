-- The tree painter (tracker "NEW UI HOST" task 2): walks a tree annotated by
-- layout.compute and paints it onto a Canvas. Per node, in order: background
-- (props.hl over the border box), border (per-side chars, corners only where
-- both adjacent sides exist), then content — text clipped to the content box,
-- container children recursively (children paint over their parent).

local Canvas = require("fibrous.inline.canvas")

local width = require("fibrous.inline.width")
local char_width, str_width = width.char, width.str

local M = {}

local CONTAINERS = { col = true, row = true }

-- Crop `str` to at most `max_w` display cells.
---@param str string
---@param max_w integer
---@return string
local function crop(str, max_w)
  if str_width(str) <= max_w then
    return str
  end
  local out, w = {}, 0
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local cw = char_width(ch)
    if w + cw > max_w then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out)
end

---@param c Canvas
---@param rect { x: integer, y: integer, w: integer, h: integer }
---@param b Border
---@param hl_override string|nil  style `border_hl` — recolors without touching the spec
local function draw_border(c, rect, b, hl_override)
  local s = b.sides
  if s.top + s.right + s.bottom + s.left == 0 then
    return
  end
  local hl = hl_override or b.hl or "FibrousBorder"
  local x0, y0 = rect.x, rect.y
  local x1, y1 = rect.x + rect.w - 1, rect.y + rect.h - 1

  -- Edges via direct put (bounds-safe) with the char width computed once —
  -- border cells are a large share of all painted cells (task 8 bench).
  if s.top == 1 then
    local ch, cw = b.chars.top, char_width(b.chars.top)
    for x = x0 + s.left, x1 - s.right do
      c:put(x, y0, ch, hl, cw)
    end
  end
  if s.bottom == 1 then
    local ch, cw = b.chars.bottom, char_width(b.chars.bottom)
    for x = x0 + s.left, x1 - s.right do
      c:put(x, y1, ch, hl, cw)
    end
  end
  if s.left == 1 then
    local ch, cw = b.chars.left, char_width(b.chars.left)
    for y = y0 + s.top, y1 - s.bottom do
      c:put(x0, y, ch, hl, cw)
    end
  end
  if s.right == 1 then
    local ch, cw = b.chars.right, char_width(b.chars.right)
    for y = y0 + s.top, y1 - s.bottom do
      c:put(x1, y, ch, hl, cw)
    end
  end

  -- Corners only where both adjacent sides exist.
  if s.top == 1 and s.left == 1 then
    c:put(x0, y0, b.chars.tl, hl, char_width(b.chars.tl))
  end
  if s.top == 1 and s.right == 1 then
    c:put(x1, y0, b.chars.tr, hl, char_width(b.chars.tr))
  end
  if s.bottom == 1 and s.left == 1 then
    c:put(x0, y1, b.chars.bl, hl, char_width(b.chars.bl))
  end
  if s.bottom == 1 and s.right == 1 then
    c:put(x1, y1, b.chars.br, hl, char_width(b.chars.br))
  end

  -- Title, painted over its edge (between the corners) after the edge chars.
  local t = b.title
  if t and s[t.pos] == 1 then
    local span_w = rect.w - s.left - s.right
    local text = crop(t.text, math.max(span_w, 0))
    if text ~= "" then
      local x = x0 + s.left
      local tw = str_width(text)
      if t.align == "center" then
        x = x + math.floor((span_w - tw) / 2)
      elseif t.align == "right" then
        x = x + span_w - tw
      end
      c:text(x, t.pos == "top" and y0 or y1, text, t.hl or hl)
    end
  end
end

---@param c Canvas
---@param node table  a node annotated by layout.compute
local function visit(c, node)
  local rect = node.rect
  if rect.w <= 0 or rect.h <= 0 then
    return
  end
  local props = node.props or {}
  -- Host-built nodes carry a state-resolved style; raw trees style from props.
  local rs = node.style_resolved
  local bg = rs and rs.hl or props.hl
  local text_hl = rs and rs.text_hl or props.text_hl

  if bg then
    c:hl_rect(rect, bg)
  end
  draw_border(c, rect, node.box.border, rs and rs.border_hl)

  if node.kind == "text" then
    local content = node.content
    for i, line in ipairs(node.lines) do
      if i > content.h then
        break
      end
      local y = content.y + i - 1
      local runs = node.line_runs and node.line_runs[i]
      if runs then
        -- Span-list text: paint per attribution run, hl-less runs falling
        -- back to the node's text_hl.
        local x, remaining = content.x, content.w
        for _, run in ipairs(runs) do
          if remaining <= 0 then
            break
          end
          local chunk = crop(run.text, remaining)
          c:text(x, y, chunk, run.hl or text_hl)
          local cw = str_width(chunk)
          x, remaining = x + cw, remaining - cw
        end
      else
        c:text(content.x, y, crop(line, content.w), text_hl)
      end
    end
  elseif CONTAINERS[node.kind] then
    for _, child in ipairs(node.children or {}) do
      visit(c, child)
    end
  end
end

-- Paint a laid-out tree onto a fresh (w × h) canvas.
---@param tree table  annotated by layout.compute
---@param w integer   canvas width (the root margin-box width)
---@param h integer   canvas height
---@return Canvas
function M.paint(tree, w, h)
  local c = Canvas.new(w, h)
  visit(c, tree)
  return c
end

return M
