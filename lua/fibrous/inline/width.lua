-- Display-width helpers with caching (tracker "NEW UI HOST" task 8 perf
-- posture: "cache strwidth lookups"). nvim_strwidth is an API call with
-- real per-call overhead; layout wrapping and canvas painting query widths
-- per character, hundreds of thousands of times per commit. A char-keyed
-- memo (the working set is tiny — the distinct chars on screen) and an
-- ASCII fast path for whole strings remove nearly all of those calls.

local api_strwidth = vim.api.nvim_strwidth

local M = {}

-- char → display width. Unbounded on purpose: it can only grow to the number
-- of distinct characters ever rendered.
local cache = {}

-- Display width of ONE UTF-8 character.
---@param ch string
---@return integer
function M.char(ch)
  local w = cache[ch]
  if w == nil then
    w = api_strwidth(ch)
    cache[ch] = w
  end
  return w
end

-- Display width of a string. Printable ASCII (the overwhelmingly common case)
-- is just its byte length; anything else goes to the API once per call.
---@param s string
---@return integer
function M.str(s)
  if s:find("^[ -~]*$") then
    return #s
  end
  return api_strwidth(s)
end

-- Is `ch` a composing (combining) character? charclass == 2 is the reliable
-- signal: a LONE combining char measures width 1 via nvim_strwidth, so width
-- alone cannot identify it. Memoized like the widths (tiny working set).
local charclass = vim.fn.charclass
local combining = {}
---@param ch string  one UTF-8 character
---@return boolean
function M.is_combining(ch)
  local v = combining[ch]
  if v == nil then
    v = #ch > 1 and charclass(ch) == 2
    combining[ch] = v
  end
  return v
end

-- Iterate the grapheme clusters of `s`: each head char plus the combining
-- chars composed onto it. Per-codepoint iteration mis-widths composed text
-- (the lone-combining-char width-1 problem above); cluster-wise, `M.char` of
-- the whole cluster is the composed width. ASCII bytes short-circuit the
-- charclass lookup.
---@param s string
---@return fun(): string|nil
function M.clusters(s)
  local nextc = s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
  local head = nextc()
  return function()
    if head == nil then
      return nil
    end
    local cluster = head
    local ch = nextc()
    while ch and #ch > 1 and M.is_combining(ch) do
      cluster = cluster .. ch
      ch = nextc()
    end
    head = ch
    return cluster
  end
end

-- Byte offset of display-cell column `cell` in `line` (extmark cols, cursor
-- cols). Shared by the hit-map (interact) and subwindow focus traversal.
-- Walks CLUSTERS: buffer lines can hold composed text (image placeholder
-- rows are nothing but clusters), and a split cluster lands the cursor on a
-- combining char.
---@param line string
---@param cell integer
---@return integer
function M.cell_to_byte(line, cell)
  if cell <= 0 then
    return 0
  end
  if line:find("^[ -~]*$") then
    return math.min(cell, #line)
  end
  local w, b = 0, 0
  for cluster in M.clusters(line) do
    if w >= cell then
      break
    end
    b = b + #cluster
    w = w + M.char(cluster)
  end
  return b
end

return M
