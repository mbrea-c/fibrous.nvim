-- Rich-text span lists ("Style rework" S4). A text node's `text` (and the
-- label/paragraph `text` prop) may be a list of spans — bare strings or
-- { "chunk", hl = ... } tables. This module is the pure half: flatten a list
-- into the full text plus byte-indexed hl ranges, and re-attribute output
-- lines (assembled by the layout engine's wrap) back to those ranges as
-- paint-ready runs. A span may also carry interaction (`style._hover`,
-- `on_click`, `role`); such a span gets a stable logical `id` threaded onto its
-- runs, which the cursor layer (interact.lua) and target registry (targets.lua)
-- read for span-level hover, click, and flash jumping.

local style = require("fibrous.inline.style")

local M = {}

---@alias Span string|{ [1]: string, hl?: string, style?: table, on_click?: fun(x?: integer), role?: string }

---@class SpanRange
---@field s integer  1-indexed source byte start
---@field e integer  end-exclusive source byte
---@field hl string|nil  the run's foreground group (style.text_hl, or legacy flat `hl`)
---@field hover_hl string|nil  group applied while the span is hovered (style._hover.text_hl)
---@field on_click fun(x?: integer)|nil  fired by click / <CR> when the cursor is on the span
---@field role string|nil  targets/flash kind marker (e.g. "link")
---@field id integer|nil  stable logical-span id: every run this span wraps into shares it

-- Flatten a span list into the full text plus the byte ranges that attribute it.
-- A style-only span (legacy `hl`, or `style = { text_hl }`) yields a bare
-- { s, e, hl } range, unchanged. An INTERACTIVE span (any of `_hover`,
-- `on_click`, `role`) additionally gets a stable `id` and its interaction
-- fields, so its wrapped runs can be grouped back together downstream.
---@param list Span[]
---@return string text, SpanRange[] ranges
function M.flatten(list, default_source)
  local parts, ranges = {}, {}
  local pos = 1
  local next_id = 0
  for i, span in ipairs(list) do
    local text, hl, hover_hl, on_click, role, source
    if type(span) == "string" then
      text = span
    elseif type(span) == "table" and type(span[1]) == "string" then
      text = span[1]
      on_click, role, source = span.on_click, span.role, span.source
      if span.style ~= nil then
        local ss = style.span_style(span.style)
        hl = ss.base.text_hl
        hover_hl = ss.hover and ss.hover.text_hl or nil
      end
      -- legacy flat `hl` is the run's group; an explicit style.text_hl wins
      if hl == nil then
        hl = span.hl
      end
    else
      error(('fibrous: text span %d must be a string or { "text", hl?/style?/on_click?/role? }'):format(i))
    end
    parts[#parts + 1] = text
    local interactive = hover_hl ~= nil or on_click ~= nil or role ~= nil
    if hl or interactive or source or default_source then
      local range = { s = pos, e = pos + #text, hl = hl }
      if source or default_source then
        range.source, range.source_base = source or default_source, source and 1 or pos
      end
      if interactive then
        next_id = next_id + 1
        range.id = next_id
        range.hover_hl = hover_hl
        range.on_click = on_click
        range.role = role
      end
      ranges[#ranges + 1] = range
    end
    pos = pos + #text
  end
  return table.concat(parts), ranges
end

-- The range covering source byte `pos`, or nil. Ranges are few (one per styled
-- or interactive span), so a linear scan is fine.
---@param ranges SpanRange[]
---@param pos integer
---@return SpanRange|nil
function M.attr_at(ranges, pos)
  for _, r in ipairs(ranges) do
    if pos >= r.s and pos < r.e then
      return r
    end
  end
  return nil
end

-- The hl covering source byte `pos`, or nil.
---@param ranges SpanRange[]
---@param pos integer
---@return string|nil
function M.hl_at(ranges, pos)
  local r = M.attr_at(ranges, pos)
  return r and r.hl or nil
end

---@class SpanRun
---@field text string
---@field hl string|nil  foreground group; nil = the node's text_hl applies
---@field hover_hl string|nil  group applied while hovered (interactive spans)
---@field on_click fun(x?: integer)|nil  fired by click / <CR> on this run
---@field role string|nil  targets/flash kind marker
---@field id integer|nil  logical-span id (shared by every run of one span)

-- Attribute one output line back to the source: `pieces` are the chunks the
-- wrap assembled the line from, in order, each mapping its bytes 1:1 to the
-- source from byte `s` (a join space is a 1-byte piece pointing at the gap it
-- replaced). Adjacent segments merge when they carry the SAME attribution:
-- same hl AND same logical id, so two distinct interactive spans never fuse
-- while a single span's pieces still coalesce.
---@param pieces { s: integer, text: string }[]
---@param ranges SpanRange[]
---@return SpanRun[]
function M.runs(pieces, ranges)
  local runs = {}
  for _, p in ipairs(pieces) do
    -- Flattened ranges are ordered and disjoint. Seek once per piece, then
    -- jump between boundaries instead of rescanning the ranges for every byte.
    -- Each piece seeks independently, so reordered source pieces still work.
    local lo, hi = 1, #ranges
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      if ranges[mid].e <= p.s then lo = mid + 1 else hi = mid - 1 end
    end
    local ri, i = lo, 1
    while i <= #p.text do
      local at = p.s + i - 1
      while ranges[ri] and ranges[ri].e <= at do ri = ri + 1 end
      local r = ranges[ri]
      local j = #p.text + 1
      if r then
        if at < r.s then
          j, r = math.min(j, r.s - p.s + 1), nil
        else j = math.min(j, r.e - p.s + 1) end
      end
      local chunk = p.text:sub(i, j - 1)
      local hl = r and r.hl or nil
      local id = r and r.id or nil
      local source = r and r.source
      local positions
      if source then
        positions = {}
        for k = i, j - 1 do
          local at = r.source_base + p.s + k - 1 - r.s
          local mapped = source.map and source.map[at] or not source.map and at - 1
          positions[#positions + 1] = type(mapped) == "number" and (source.offset or 0) + mapped or false
        end
      end
      local last = runs[#runs]
      if last and last.hl == hl and last.id == id and last.source == source then
        last.text = last.text .. chunk
        if positions then for _, position in ipairs(positions) do last.source_positions[#last.source_positions + 1] = position end end
      else
        runs[#runs + 1] = {
          text = chunk,
          hl = hl,
          source = source, source_positions = positions,
          id = id,
          hover_hl = r and r.hover_hl or nil,
          on_click = r and r.on_click or nil,
          role = r and r.role or nil,
        }
      end
      i = j
    end
  end
  return runs
end

return M
