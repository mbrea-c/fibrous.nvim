-- Shared cell geometry for inline overflow. Clips restrict paint and input;
-- they do not change measurement, scrolling, or allocate native windows.
local width = require("fibrous.inline.width")
local M = {}

function M.equal(a, b)
  return a == b or (a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h)
end

function M.intersect(a, b)
  if not b then return a end
  local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
  return { x = x, y = y,
    w = math.max(0, math.min(a.x + a.w, b.x + b.w) - x),
    h = math.max(0, math.min(a.y + a.h, b.y + b.h) - y) }
end

function M.visible(node, rect)
  return M.intersect(rect or node.rect, node.clip)
end

function M.contains(rect, x, y)
  return rect and x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

-- Crop display cells, preserving combining clusters. A cut wide glyph becomes
-- a space for its visible half.
function M.slice(text, left, right)
  if text:find("^[ -~]*$") then return text:sub(left + 1, right) end
  local out, x = {}, 0
  for ch in width.clusters(text) do
    local w = width.char(ch)
    if x >= right then break end
    if x + w > left then
      out[#out + 1] = x >= left and x + w <= right and ch
        or (" "):rep(math.max(0, math.min(x + w, right) - math.max(x, left)))
    end
    x = x + w
  end
  return table.concat(out)
end

local View = {}
View.__index = View
function View:put(x, y, ch, hl, w)
  if y < self.clip.y or y >= self.clip.y + self.clip.h then return end
  local left, right = math.max(x, self.clip.x), math.min(x + w, self.clip.x + self.clip.w)
  if right <= left then return end
  if left ~= x or right ~= x + w then
    self.base:text(left, y, (" "):rep(right - left), hl)
  else
    self.base:put(x, y, ch, hl, w)
  end
end
function View:text(x, y, text, hl)
  local r = self.clip
  if y < r.y or y >= r.y + r.h then return end
  local left, right = math.max(x, r.x), r.x + r.w
  if left >= right then return end
  self.base:text(left, y, M.slice(text, left - x, right - x), hl)
end
function View:hl_rect(rect, hl)
  self.base:hl_rect(M.intersect(rect, self.clip), hl)
end

function M.canvas(canvas, rect)
  if not rect or canvas.clip == rect then return canvas end
  local base = canvas.base or canvas
  return setmetatable({ base = base, clip = rect }, View)
end

return M
