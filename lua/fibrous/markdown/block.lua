-- The block phase of the markdown parser: source text to a raw block tree.
-- Line-based and pure Lua (no Neovim, no treesitter). "Raw" means leaf blocks
-- carry their inline content as a plain string; init.lua runs the inline phase
-- over those and lowers the whole tree into fibrous.doc.ast.
--
-- Raw block shapes:
--   { kind="heading", level, text }
--   { kind="paragraph", text }                 (lines joined by \n)
--   { kind="code_block", lang, text }          (verbatim; no inline parse)
--   { kind="thematic_break" }
--   { kind="blockquote", blocks }              (recursively parsed)
--   { kind="list", ordered, start, tight, items = { { blocks, checked } } }
--
-- Scope is a documented subset: ATX headings, fenced code, thematic breaks,
-- blockquotes, ordered/unordered/task lists (tight), and paragraphs. Setext
-- headings, indented code blocks, and loose-list spacing are not modeled yet.

local M = {}

local function split_lines(text)
  text = text:gsub("\r\n?", "\n")
  local lines, start = {}, 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- ATX heading → level, text (nil when not a heading).
local function atx(line)
  local hashes, rest = line:match("^(#+)%s+(.*)$")
  if hashes and #hashes <= 6 then
    return #hashes, (rest:gsub("%s+#+%s*$", ""))
  end
  hashes = line:match("^(#+)%s*$")
  if hashes and #hashes <= 6 then
    return #hashes, ""
  end
  return nil
end

-- Fence → char, length, info, indent (nil when not a fence line).
local function fence(line)
  local indent, ticks, info = line:match("^(%s*)(`+)%s*(.*)$")
  if ticks and #ticks >= 3 then
    return "`", #ticks, info, #indent
  end
  indent, ticks, info = line:match("^(%s*)(~+)%s*(.*)$")
  if ticks and #ticks >= 3 then
    return "~", #ticks, info, #indent
  end
  return nil
end

local function thematic(line)
  local only = line:gsub("%s", "")
  if #only < 3 then
    return false
  end
  return only:match("^%-+$") ~= nil or only:match("^%*+$") ~= nil or only:match("^_+$") ~= nil
end

-- List marker → { ordered, indent, rest, markw, start } (nil when none). markw
-- is the content column (how far to strip for continuation/nested lines).
local function marker(line)
  local indent, bullet, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  if bullet then
    return { ordered = false, indent = #indent, rest = rest, markw = #indent + 2 }
  end
  local num, delim
  indent, num, delim, rest = line:match("^(%s*)(%d+)([.)])%s+(.*)$")
  if num then
    return { ordered = true, indent = #indent, rest = rest, markw = #indent + #num + 2, start = tonumber(num) }
  end
  return nil
end

-- Split a GFM table row into trimmed cells, honoring `\|` escapes and dropping
-- the optional leading/trailing border pipes.
local function split_cells(line)
  line = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells, cur, i = {}, {}, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == "\\" and i < #line then
      cur[#cur + 1] = line:sub(i + 1, i + 1)
      i = i + 2
    elseif c == "|" then
      cells[#cells + 1] = (table.concat(cur):gsub("^%s+", ""):gsub("%s+$", ""))
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = (table.concat(cur):gsub("^%s+", ""):gsub("%s+$", ""))
  return cells
end

-- A GFM delimiter row (`| :--- | ---: |`) → the per-column alignment list, or
-- nil when the line is not a delimiter row.
local function delimiter_align(line)
  if not line:find("|") and not line:find("%-") then
    return nil
  end
  local cells = split_cells(line)
  if #cells == 0 then
    return nil
  end
  local align = {}
  for _, cell in ipairs(cells) do
    local spec = cell:match("^(:?%-+:?)$")
    if not spec then
      return nil
    end
    local left, right = spec:sub(1, 1) == ":", spec:sub(-1) == ":"
    align[#align + 1] = (left and right) and "center" or (right and "right") or (left and "left") or nil
  end
  return align
end

local parse_lines -- forward

local function parse_list(lines, start)
  local first = marker(lines[start])
  local ordered = first.ordered
  local items = {}
  local i, n = start, #lines
  while i <= n do
    local m = not is_blank(lines[i]) and marker(lines[i]) or nil
    if not m or m.ordered ~= ordered or m.indent >= first.markw then
      break
    end
    local contw = m.markw
    local item_lines = { m.rest }
    i = i + 1
    while i <= n and not is_blank(lines[i]) do
      local l = lines[i]
      local lead = #(l:match("^ *"))
      if marker(l) and lead < contw then
        break -- a sibling / shallower marker ends this item
      end
      if lead >= contw then
        item_lines[#item_lines + 1] = l:sub(contw + 1)
        i = i + 1
      else
        break
      end
    end
    -- GFM task marker at the item head
    local checked
    local box, after = item_lines[1]:match("^%[([ xX])%]%s+(.*)$")
    if box then
      checked = box == "x" or box == "X"
      item_lines[1] = after
    end
    items[#items + 1] = { blocks = parse_lines(item_lines), checked = checked }
    -- allow a single blank line before a continuing sibling (rendered tight)
    if i <= n and is_blank(lines[i]) then
      local j = i
      while j <= n and is_blank(lines[j]) do
        j = j + 1
      end
      local nm = j <= n and marker(lines[j]) or nil
      if nm and nm.ordered == ordered and nm.indent < first.markw then
        i = j
      else
        break
      end
    end
  end
  return { kind = "list", ordered = ordered, start = first.start, tight = true, items = items }, i
end

function parse_lines(lines)
  local blocks = {}
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    if is_blank(line) then
      i = i + 1
    elseif atx(line) then
      local level, text = atx(line)
      blocks[#blocks + 1] = { kind = "heading", level = level, text = text }
      i = i + 1
    elseif fence(line) then
      local ch, len, info = fence(line)
      local body = {}
      i = i + 1
      while i <= n do
        local fch, flen = fence(lines[i])
        if fch == ch and flen >= len and lines[i]:match("^%s*[`~]+%s*$") then
          i = i + 1
          break
        end
        body[#body + 1] = lines[i]
        i = i + 1
      end
      local lang = info ~= "" and info:match("^(%S+)") or nil
      blocks[#blocks + 1] = { kind = "code_block", lang = lang, text = table.concat(body, "\n") }
    elseif line:match("^%s*%$%$") then
      -- display math block: $$ ... $$ (same line, or opening $$ then lines then $$)
      local rest = line:gsub("^%s*%$%$", "")
      local closed = rest:match("^(.-)%$%$%s*$")
      if closed then
        blocks[#blocks + 1] = { kind = "math", tex = closed }
        i = i + 1
      else
        local body = { rest }
        i = i + 1
        while i <= n and not lines[i]:match("%$%$") do
          body[#body + 1] = lines[i]
          i = i + 1
        end
        if i <= n then
          body[#body + 1] = (lines[i]:gsub("%$%$.*$", ""))
          i = i + 1
        end
        -- drop a leading empty line from "$$\n..." and trailing empties
        local tex = table.concat(body, "\n"):gsub("^%s*\n", ""):gsub("%s+$", "")
        blocks[#blocks + 1] = { kind = "math", tex = tex }
      end
    elseif thematic(line) then
      blocks[#blocks + 1] = { kind = "thematic_break" }
      i = i + 1
    elseif line:match("^%s*>") then
      local inner = {}
      while i <= n and lines[i]:match("^%s*>") do
        inner[#inner + 1] = (lines[i]:gsub("^%s*> ?", ""))
        i = i + 1
      end
      blocks[#blocks + 1] = { kind = "blockquote", blocks = parse_lines(inner) }
    elseif line:find("|") and i < n and delimiter_align(lines[i + 1]) then
      local align = delimiter_align(lines[i + 1])
      local header = split_cells(line)
      i = i + 2
      local rows = {}
      while i <= n and not is_blank(lines[i]) and lines[i]:find("|") do
        rows[#rows + 1] = split_cells(lines[i])
        i = i + 1
      end
      blocks[#blocks + 1] = { kind = "table", align = align, header = header, rows = rows }
    elseif not is_blank(line) and marker(line) then
      local list, nexti = parse_list(lines, i)
      blocks[#blocks + 1] = list
      i = nexti
    else
      local para = {}
      while
        i <= n
        and not is_blank(lines[i])
        and not atx(lines[i])
        and not fence(lines[i])
        and not thematic(lines[i])
        and not lines[i]:match("^%s*>")
        and not marker(lines[i])
        and not (lines[i]:find("|") and i < n and delimiter_align(lines[i + 1]))
      do
        para[#para + 1] = (lines[i]:gsub("^%s+", ""))
        i = i + 1
      end
      blocks[#blocks + 1] = { kind = "paragraph", text = table.concat(para, "\n") }
    end
  end
  return blocks
end

-- Parse markdown source into the raw block tree.
---@param text string
---@return table[] blocks
function M.parse(text)
  return parse_lines(split_lines(text))
end

return M
