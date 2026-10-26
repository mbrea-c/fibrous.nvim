-- The inline phase of the markdown parser: a leaf block's raw text to
-- fibrous.doc.ast inline nodes. Pure Lua, no Neovim, no treesitter.
--
-- Scope (documented subset, expanded over time): backslash escapes, code
-- spans, images, links (inline destinations with an optional title),
-- autolinks, strong/emphasis (* and _), GFM strikethrough (~~), and
-- soft/hard line breaks. Emphasis uses a pragmatic same-delimiter match with
-- simplified flanking checks (see can_open/can_close) rather than the full
-- CommonMark delimiter-run algorithm, so a few pathological nestings differ
-- from the reference; the common cases — including literal snake_case
-- identifiers and space-separated asterisks — are exact.

local ast = require("fibrous.doc.ast")
local Source = require("fibrous.doc.source")

local M = {}

local parse -- forward (recursion into emphasis/link content)

-- Syntax starters; all other bytes can be buffered as a single plain run.
local SPECIAL = "[\\\n`$!%[<*_~]"

-- Index of the next literal `needle` at or after `from` that is not backslash
-- escaped, or nil.
local function find_unescaped(text, from, needle)
  local i = from
  while true do
    local s = text:find(needle, i, true)
    if not s then
      return nil
    end
    if s == 1 or text:sub(s - 1, s - 1) ~= "\\" then
      return s
    end
    i = s + 1
  end
end

-- A code span opening with a run of `n` backticks at `i`: match a CLOSING run of
-- exactly n backticks. Returns the code text and the index past the close, or nil.
local function code_span(text, i, map)
  local open = text:match("^`+", i)
  local n = #open
  local j = i + n
  while true do
    local s = text:find("`+", j)
    if not s then
      return nil
    end
    local run = text:match("^`+", s)
    if #run == n then
      local content = text:sub(i + n, s - 1)
      local start, finish = i + n, s - 1
      -- CommonMark strips one leading and trailing space when both are present
      content = content:gsub("\n", " ")
      if content:match("^ .* $") then
        content = content:sub(2, -2)
        start, finish = start + 1, finish - 1
      end
      return Source.node(ast.code_span(content), Source.slice(map, start, finish)), s + n
    end
    j = s + #run
  end
end

-- A link/image body `[text](url "title")` starting at the label's `[` (index
-- `lb`). `is_image` shifts nothing (caller already consumed the `!`). Returns
-- the node and the index past the close, or nil when it is not a valid link.
local function link_like(text, lb, is_image, map)
  -- balanced label up to the matching ]
  local depth, i = 0, lb
  local label_end
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 2
    else
      if c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
        if depth == 0 then
          label_end = i
          break
        end
      end
      i = i + 1
    end
  end
  if not label_end or text:sub(label_end + 1, label_end + 1) ~= "(" then
    return nil
  end
  local close = find_unescaped(text, label_end + 2, ")")
  if not close then
    return nil
  end
  local label = text:sub(lb + 1, label_end - 1)
  local dest = text:sub(label_end + 2, close - 1)
  -- split destination and optional "title"
  local url, title = dest:match('^%s*(%S+)%s+"([^"]*)"%s*$')
  if not url then
    url = dest:match("^%s*(%S*)%s*$") or dest
  end
  if is_image then
    return Source.node(ast.image(url, label, title), Source.slice(map, lb + 1, label_end - 1)), close + 1
  end
  return ast.link(url, title, parse(label, Source.slice(map, lb + 1, label_end - 1))), close + 1
end

-- Simplified flanking (the CommonMark common cases without the full
-- delimiter-run algorithm): a run can OPEN only when followed by
-- non-whitespace and CLOSE only when preceded by non-whitespace — so
-- "2 * 3 * 4" stays literal. Underscore runs additionally never bind INSIDE
-- a word (CommonMark's intraword-underscore rule): they open only after a
-- non-word character and close only before one, so pending_edits and
-- _foo_bar are literal while *b* keeps working intraword. Word = ASCII %w;
-- a multibyte char before/after an underscore counts as non-word, which is
-- looser than the spec's unicode classes but on the safe (literal) side for
-- identifiers.
local function can_open(text, i, d)
  local after = text:sub(i + #d, i + #d)
  if after == "" or after:match("%s") then
    return false
  end
  return d:sub(1, 1) ~= "_" or not text:sub(i - 1, i - 1):match("%w")
end

local function can_close(text, s, d)
  local before = text:sub(s - 1, s - 1)
  if before == "" or before:match("%s") then
    return false
  end
  return d:sub(1, 1) ~= "_" or not text:sub(s + #d, s + #d):match("%w")
end

-- An emphasis/strong/strikethrough run with delimiter `d` at `i`. Finds the
-- next matching `d` that may close (skipping candidates flanking forbids),
-- parses the inside, wraps it in `make`. Returns node, next index.
local function delimited(text, i, d, make, map)
  if not can_open(text, i, d) then
    return nil
  end
  local close = find_unescaped(text, i + #d, d)
  while close and not can_close(text, close, d) do
    close = find_unescaped(text, close + 1, d)
  end
  if not close then
    return nil
  end
  local inner = text:sub(i + #d, close - 1)
  if inner == "" then
    return nil
  end
  return make(parse(inner, Source.slice(map, i + #d, close - 1))), close + #d
end

parse = function(text, map)
  local out = {}
  local buf, positions = {}, map and {}
  local function push(value, from)
    buf[#buf + 1] = value
    if positions then for j = 1, #value do positions[#positions + 1] = map[from + j - 1] end end
  end
  local function flush(trim)
    if #buf > 0 then
      local text = table.concat(buf)
      if trim then text = text:sub(1, trim) end
      out[#out + 1] = Source.node(ast.text(text), positions and Source.slice(positions, 1, #text))
      buf, positions = {}, map and {}
    end
  end

  local i, n = 1, #text
  while i <= n do
    local special = text:find(SPECIAL, i)
    if special ~= i then
      push(text:sub(i, (special or n + 1) - 1), i)
      i = special or n + 1
      if i > n then break end
    end
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)

    if c == "\\" and i < n and text:sub(i + 1, i + 1):match("%p") then
      push(text:sub(i + 1, i + 1), i + 1)
      i = i + 2
    elseif c == "\n" then
      -- two+ trailing spaces (or a trailing backslash) before the newline = a
      -- hard break; otherwise a soft break. Trim the trailing marker either way.
      local acc = table.concat(buf)
      local hard = acc:match("  +$") ~= nil or acc:match("\\$") ~= nil
      local trimmed = (acc:gsub("%s+$", "")):gsub("\\$", "")
      if trimmed ~= "" then flush(#trimmed) else buf, positions = {}, map and {} end
      out[#out + 1] = Source.node(hard and ast.hardbreak() or ast.softbreak(), Source.slice(map, i, i))
      i = i + 1
    elseif c == "`" then
      local node, nexti = code_span(text, i, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(c, i)
        i = i + 1
      end
    elseif c == "$" and text:sub(i + 1, i + 1) ~= "$" then
      -- inline math $...$ (GFM rule: opener not followed by a space, closer not
      -- preceded by a space, and a digit right after the opener does not open —
      -- so prose like "$5 and $10" is left alone).
      local after = text:sub(i + 1, i + 1)
      local close
      if after ~= "" and not after:match("[%s%d]") then
        close = find_unescaped(text, i + 1, "$")
        while close and text:sub(close - 1, close - 1):match("%s") do
          close = find_unescaped(text, close + 1, "$")
        end
      end
      if close and close > i + 1 then
        flush()
        out[#out + 1] = ast.math_inline(text:sub(i + 1, close - 1))
        i = close + 1
      else
        push(c, i)
        i = i + 1
      end
    elseif two == "![" then
      local node, nexti = link_like(text, i + 1, true, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(c, i)
        i = i + 1
      end
    elseif c == "[" then
      local node, nexti = link_like(text, i, false, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(c, i)
        i = i + 1
      end
    elseif c == "<" then
      local url, nexti = text:match("^<(%a[%w+.-]*:[^%s>]+)>()", i)
      if not url then
        url, nexti = text:match("^<([^%s@>]+@[^%s@>]+%.[^%s>]+)>()", i)
        url = url and ("mailto:" .. url) or nil
      end
      if url then
        flush()
        local shown = url:gsub("^mailto:", "")
        local skip = #(text:sub(i + 1, nexti - 2)) - #shown
        local label = Source.node(ast.text(shown), Source.slice(map, i + 1 + skip, nexti - 2))
        out[#out + 1] = ast.link(url, nil, { label })
        i = nexti
      else
        push(c, i)
        i = i + 1
      end
    elseif two == "**" or two == "__" then
      local node, nexti = delimited(text, i, two, ast.strong, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(two, i)
        i = i + 2
      end
    elseif two == "~~" then
      local node, nexti = delimited(text, i, "~~", ast.strikethrough, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(two, i)
        i = i + 2
      end
    elseif c == "*" or c == "_" then
      local node, nexti = delimited(text, i, c, ast.emph, map)
      if node then
        flush()
        out[#out + 1] = node
        i = nexti
      else
        push(c, i)
        i = i + 1
      end
    else
      buf[#buf + 1] = c
      if positions then positions[#positions + 1] = map[i] end
      i = i + 1
    end
  end
  flush()
  return out
end

-- Parse a run of inline source text into fibrous.doc.ast inline nodes.
---@param text string
---@return table[] nodes
function M.parse(text, map)
  return parse(text, map)
end

return M
