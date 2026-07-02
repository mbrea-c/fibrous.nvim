-- Cell-grid canvas for the inline host (tracker "NEW UI HOST" task 2). The
-- renderer paints the laid-out tree onto it; the host flushes it to a buffer
-- as whole lines plus extmark highlight spans. Coordinates are 0-indexed grid
-- cells (columns/rows), while `highlights()` reports BYTE offsets — exactly
-- what nvim_buf_set_extmark takes — merging adjacent same-hl cells into spans.
--
-- Multibyte: each cell stores one UTF-8 char. A double-width char occupies its
-- head cell (width 2) plus a continuation cell (char "", width 0) so joined
-- lines stay display-aligned; overwriting either half blanks the other.
--
-- Storage is parallel per-row arrays (chars / widths / highlights) rather than
-- a table per cell — painting is the hot path of every commit (task 8 bench),
-- and per-cell tables made allocation dominate. `text` takes a byte-indexed
-- fast path for printable-ASCII strings (the overwhelmingly common case).

local char_width = require("fibrous.inline.width").char

---@class Canvas
---@field w integer
---@field h integer
---@field ch string[][]        per-row cell chars ("" = wide-char continuation)
---@field cw integer[][]       per-row cell widths (1, 2 = wide head, 0 = continuation)
---@field hl table<integer, string>[]  per-row cell highlights (sparse)
local Canvas = {}
Canvas.__index = Canvas

local M = {}

---@param w integer
---@param h integer
---@return Canvas
function M.new(w, h)
  local ch, cw, hl = {}, {}, {}
  for y = 1, h do
    local cr, wr = {}, {}
    for x = 1, w do
      cr[x] = " "
      wr[x] = 1
    end
    ch[y], cw[y], hl[y] = cr, wr, {}
  end
  return setmetatable({ w = w, h = h, ch = ch, cw = cw, hl = hl }, Canvas)
end

-- Iterate the UTF-8 characters of `s`.
local function chars(s)
  return s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- Write one char into cell (x, y); out-of-bounds writes are ignored.
-- Overwriting either half of an existing wide char blanks the other half. A
-- nil hl leaves the cell's current hl in place (so text drawn over an hl_rect
-- keeps the rect's background).
---@param x integer  0-indexed column
---@param y integer  0-indexed row
---@param ch string
---@param hl string|nil
---@param w integer  display width of ch
function Canvas:put(x, y, ch, hl, w)
  if x < 0 or x >= self.w or y < 0 or y >= self.h then
    return
  end
  local chr, cwr, hlr = self.ch[y + 1], self.cw[y + 1], self.hl[y + 1]
  local i = x + 1
  local old = cwr[i]
  if old == 0 then -- continuation: blank the wide char's head
    chr[i - 1], cwr[i - 1] = " ", 1
  elseif old == 2 and i < self.w then -- head: blank its continuation
    chr[i + 1], cwr[i + 1] = " ", 1
  end
  chr[i], cwr[i] = ch, w
  if hl then
    hlr[i] = hl
  end
  if w == 2 then
    if i < self.w then
      chr[i + 1], cwr[i + 1] = "", 0
      if hl then
        hlr[i + 1] = hl
      end
    end
  end
end

-- Write a string starting at (x, y). Out-of-bounds cells clip silently; a
-- double-width char that would be cut by the right edge degrades to a space.
---@param x integer
---@param y integer
---@param str string
---@param hl string|nil
function Canvas:text(x, y, str, hl)
  if y < 0 or y >= self.h then
    return
  end

  if str:find("^[ -~]*$") then
    -- Printable ASCII: one byte per cell, no wide chars to produce.
    local chr, cwr, hlr = self.ch[y + 1], self.cw[y + 1], self.hl[y + 1]
    local from = x < 0 and (1 - x) or 1
    local to = math.min(#str, self.w - x)
    for k = from, to do
      local i = x + k
      local old = cwr[i]
      if old == 0 then
        chr[i - 1], cwr[i - 1] = " ", 1
      elseif old == 2 and i < self.w then
        chr[i + 1], cwr[i + 1] = " ", 1
      end
      chr[i], cwr[i] = str:sub(k, k), 1
      if hl then
        hlr[i] = hl
      end
    end
    return
  end

  for ch in chars(str) do
    local w = char_width(ch)
    if x + w > self.w then
      if x >= 0 and x < self.w then
        self:put(x, y, " ", hl, 1) -- the on-canvas half of a cut wide char
      end
      return
    end
    if x >= 0 then
      self:put(x, y, ch, hl, w)
    end
    x = x + w
  end
end

-- Paint `hl` over every cell of `rect` (0-indexed x/y, w/h extent), keeping
-- the cell text. Used for component backgrounds.
---@param rect { x: integer, y: integer, w: integer, h: integer }
---@param hl string
function Canvas:hl_rect(rect, hl)
  for y = math.max(rect.y, 0), math.min(rect.y + rect.h, self.h) - 1 do
    local hlr = self.hl[y + 1]
    for x = math.max(rect.x, 0), math.min(rect.x + rect.w, self.w) - 1 do
      hlr[x + 1] = hl
    end
  end
end

-- The canvas as buffer lines (continuation cells contribute nothing, keeping
-- wide chars display-aligned).
---@return string[]
function Canvas:lines()
  local out = {}
  for y = 1, self.h do
    out[y] = table.concat(self.ch[y])
  end
  return out
end

-- Highlight spans, byte-indexed per row, adjacent same-hl cells merged.
---@return { row: integer, start_col: integer, end_col: integer, hl: string }[]
function Canvas:highlights()
  local out = {}
  for y = 1, self.h do
    local chr, hlr = self.ch[y], self.hl[y]
    local byte = 0
    local run_hl, run_start = nil, 0
    for x = 1, self.w do
      local hl = hlr[x]
      if hl ~= run_hl then
        if run_hl then
          out[#out + 1] = { row = y - 1, start_col = run_start, end_col = byte, hl = run_hl }
        end
        run_hl, run_start = hl, byte
      end
      byte = byte + #chr[x]
    end
    if run_hl then
      out[#out + 1] = { row = y - 1, start_col = run_start, end_col = byte, hl = run_hl }
    end
  end
  return out
end

return M
