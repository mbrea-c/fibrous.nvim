-- Rich-text span lists ("Style rework" S4). A text node's `text` (and the
-- label/paragraph `text` prop) may be a list of spans — bare strings or
-- { "chunk", hl = ... } tables. This module is the pure half: flatten a list
-- into the full text plus byte-indexed hl ranges, and re-attribute output
-- lines (assembled by the layout engine's wrap) back to those ranges as
-- paint-ready runs. Span-level hit rects (links) are a later extension of the
-- same data.

local M = {}

---@alias Span string|{ [1]: string, hl?: string }

---@class SpanRange
---@field s integer  1-indexed source byte start
---@field e integer  end-exclusive source byte
---@field hl string

-- Flatten a span list into the full text plus the hl-carrying byte ranges.
---@param list Span[]
---@return string text, SpanRange[] ranges
function M.flatten(list)
  local parts, ranges = {}, {}
  local pos = 1
  for i, span in ipairs(list) do
    local text, hl
    if type(span) == "string" then
      text = span
    elseif type(span) == "table" and type(span[1]) == "string" then
      text, hl = span[1], span.hl
    else
      error(('fibrous: text span %d must be a string or { "text", hl? }'):format(i))
    end
    parts[#parts + 1] = text
    if hl then
      ranges[#ranges + 1] = { s = pos, e = pos + #text, hl = hl }
    end
    pos = pos + #text
  end
  return table.concat(parts), ranges
end

-- The hl covering source byte `pos`, or nil. Ranges are few (one per styled
-- span), so a linear scan is fine.
---@param ranges SpanRange[]
---@param pos integer
---@return string|nil
function M.hl_at(ranges, pos)
  for _, r in ipairs(ranges) do
    if pos >= r.s and pos < r.e then
      return r.hl
    end
  end
  return nil
end

---@class SpanRun
---@field text string
---@field hl string|nil  nil = the node's text_hl applies

-- Attribute one output line back to the source: `pieces` are the chunks the
-- wrap assembled the line from, in order, each mapping its bytes 1:1 to the
-- source from byte `s` (a join space is a 1-byte piece pointing at the gap it
-- replaced). Adjacent same-hl segments merge.
---@param pieces { s: integer, text: string }[]
---@param ranges SpanRange[]
---@return SpanRun[]
function M.runs(pieces, ranges)
  local runs = {}
  for _, p in ipairs(pieces) do
    local i = 1
    while i <= #p.text do
      local hl = M.hl_at(ranges, p.s + i - 1)
      local j = i + 1
      while j <= #p.text and M.hl_at(ranges, p.s + j - 1) == hl do
        j = j + 1
      end
      local chunk = p.text:sub(i, j - 1)
      local last = runs[#runs]
      if last and last.hl == hl then
        last.text = last.text .. chunk
      else
        runs[#runs + 1] = { text = chunk, hl = hl }
      end
      i = j
    end
  end
  return runs
end

return M
