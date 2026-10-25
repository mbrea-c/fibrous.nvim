-- Optional byte provenance. Maps use 1-based output bytes -> 0-based source bytes.
-- The terminal endpoint is retained so empty lines and slices remain addressable.
local M = {}

function M.slice(map, first, last)
  if not map then return nil end
  local out = {}
  for i = first, last do out[#out + 1] = map[i] end
  out[#out + 1] = map[last + 1] or ((map[last] or 0) + 1)
  return out
end

function M.identity(text, offset)
  local out = {}
  for i = 1, #text + 1 do out[i] = (offset or 0) + i - 1 end
  return out
end

function M.node(node, map)
  if map then node.source_map = map end
  return node
end

function M.lines(text)
  local lines, maps, at = {}, {}, 1
  while true do
    local ending = text:find("[\r\n]", at)
    local line = text:sub(at, ending and ending - 1 or #text)
    lines[#lines + 1], maps[#maps + 1] = line, M.identity(line, at - 1)
    if not ending then break end
    at = ending + (text:sub(ending, ending + 1) == "\r\n" and 2 or 1)
  end
  return lines, maps
end

function M.join(lines, maps)
  local text = table.concat(lines, "\n")
  if not maps then return text end
  local out = {}
  for i, line in ipairs(lines) do
    for j = 1, #line do out[#out + 1] = maps[i][j] end
    if i < #lines then out[#out + 1] = maps[i][#line + 1] end
  end
  local last = #lines
  out[#out + 1] = last > 0 and maps[last][#lines[last] + 1] or 0
  return text, out
end

function M.cells(line, map)
  local first = line:match("^%s*|()") or 1
  local last = (line:match("()|%s*$") or (#line + 1)) - 1
  local cells, maps, chars, positions = {}, {}, {}, {}
  local function flush()
    local raw = table.concat(chars)
    local start = #(raw:match("^%s*")) + 1
    local finish = #raw - #(raw:match("%s*$"))
    cells[#cells + 1] = raw:sub(start, finish)
    positions[#raw + 1] = positions[#raw] and positions[#raw] + 1 or map[first]
    maps[#maps + 1] = M.slice(positions, start, finish)
    chars, positions = {}, {}
  end
  local i = first
  while i <= last do
    local ch = line:sub(i, i)
    if ch == "\\" and i < last then
      i = i + 1
      chars[#chars + 1], positions[#positions + 1] = line:sub(i, i), map[i]
    elseif ch == "|" then flush()
    else chars[#chars + 1], positions[#positions + 1] = ch, map[i] end
    i = i + 1
  end
  flush()
  return cells, maps
end

return M
