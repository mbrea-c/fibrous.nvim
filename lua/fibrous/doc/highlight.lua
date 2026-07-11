-- First-class fenced-code highlighting for the document renderer, via the
-- detached treesitter STRING parser (no scratch buffer). Given code and a
-- language, it returns a fibrous span list (chunks tagged with their @capture
-- group); the text node then splits it across lines and paints the runs.
--
-- It degrades GRACEFULLY: no treesitter, no parser for the language, or no
-- highlights query all return nil, and the renderer falls back to plain
-- @markup.raw. That is what makes the markdown widget work unchanged in the
-- WASM docs site (no loadable parsers) while lighting up code in a real Neovim.

local M = {}

-- 0-based byte offset where each 0-based row starts.
local function line_starts(text)
  local starts = { [0] = 0 }
  local r = 0
  for i = 1, #text do
    if text:byte(i) == 10 then -- \n
      r = r + 1
      starts[r] = i
    end
  end
  return starts
end

-- Highlight is width-independent and pure in (text, lang), and re-run on every
-- relayout (the renderer has no buffer to attach a one-shot highlighter to), so
-- memoize it. A degraded result caches as `false` so a missing parser is not
-- retried each frame. Bounded: the table is dropped wholesale past the cap.
local cache = {}
local cache_n = 0
local CACHE_MAX = 1024

local compute

-- Highlight `text` as `lang`. Returns a span list, or nil to degrade to plain.
---@param text string
---@param lang string|nil
---@return table[]|nil
function M.code(text, lang)
  if not lang or lang == "" or text == "" then
    return nil
  end
  local key = lang .. "\0" .. text
  local hit = cache[key]
  if hit ~= nil then
    return hit or nil
  end
  local result = compute(text, lang)
  if cache_n >= CACHE_MAX then
    cache, cache_n = {}, 0
  end
  cache[key] = result or false
  cache_n = cache_n + 1
  return result
end

function compute(text, lang)
  local ts = vim.treesitter
  if not (ts and ts.get_string_parser and ts.query and ts.query.get) then
    return nil
  end
  local ok, parser = pcall(ts.get_string_parser, text, lang)
  if not ok or not parser then
    return nil
  end
  if not pcall(function()
    parser:parse(true)
  end) then
    return nil
  end

  local starts = line_starts(text)
  -- last-wins per byte: later (deeper) captures override, matching treesitter's
  -- own precedence closely enough for a single-language block.
  local by_byte = {}
  local any = false

  parser:for_each_tree(function(tree, ltree)
    local q = ts.query.get(ltree:lang(), "highlights")
    if not q then
      return
    end
    for id, node in q:iter_captures(tree:root(), text, 0, -1) do
      local name = q.captures[id]
      if name and name:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        local s = (starts[sr] or 0) + sc
        local e = (starts[er] or 0) + ec
        local hl = "@" .. name
        for b = s, math.min(e, #text) - 1 do
          by_byte[b] = hl
          any = true
        end
      end
    end
  end)

  if not any then
    return nil
  end

  -- coalesce equal-hl byte runs into spans (bare string when no hl)
  local spans = {}
  local i = 0
  while i < #text do
    local hl = by_byte[i]
    local j = i + 1
    while j < #text and by_byte[j] == hl do
      j = j + 1
    end
    local chunk = text:sub(i + 1, j)
    spans[#spans + 1] = hl and { chunk, hl = hl } or chunk
    i = j
  end
  return spans
end

return M
