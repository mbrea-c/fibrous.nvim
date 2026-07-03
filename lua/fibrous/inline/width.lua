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

-- Byte offset of display-cell column `cell` in `line` (extmark cols, cursor
-- cols). Shared by the hit-map (interact) and subwindow focus traversal.
---@param line string
---@param cell integer
---@return integer
function M.cell_to_byte(line, cell)
  local w, b = 0, 0
  for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if w >= cell then
      break
    end
    b = b + #ch
    w = w + M.char(ch)
  end
  return b
end

return M
