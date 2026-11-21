local function wrap(text, width, mapped)
  if width < 1 or width == math.huge or width ~= width or text:find("[^\t-\r -~]") then return end

  local lines, source = {}, mapped and {} or nil
  local base = 1
  for _, logical in ipairs(vim.split(text, "\n", { plain = true })) do
    local line, offsets, previous_end = "", mapped and {} or nil, nil
    local function append(str, start)
      line = line .. str
      if not offsets then return end
      local last = #offsets
      if last > 0 and offsets[last - 1] + offsets[last] == start then
        offsets[last] = offsets[last] + #str
      else
        offsets[last + 1], offsets[last + 2] = start, #str
      end
    end
    local function emit()
      lines[#lines + 1] = line
      if source then source[#lines] = offsets end
      line, offsets = "", mapped and {} or nil
    end
    width = math.floor(width)
    for at, word in logical:gmatch("()(%S+)") do
      local start = base + at - 1
      if line ~= "" then
        if #line + 1 + #word > width then emit()
        else append(" ", previous_end) end
      end
      if #word > width then
        for i = 1, #word, width do
          if i > 1 then emit() end
          append(word:sub(i, i + width - 1), start + i - 1)
        end
      else
        append(word, start)
      end
      previous_end = start + #word
    end
    emit()
    base = base + #logical + 1
  end
  return lines, source
end

-- Benchmark-only injection. No environment hook or alternate wrapper is added
-- to production layout.lua. Walk its closures and replace the shared wrap_text
-- upvalue with the same coalesced comparator used by the archived experiment.
local spans = require("fibrous.inline.spans")
local seen, replaced = {}, 0
local function visit(fn)
  if seen[fn] then return end
  seen[fn] = true
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == "wrap_text" then
      debug.setupvalue(fn, i, function(text, ranges, max_w)
        local lines, source = wrap(text, max_w, ranges ~= nil)
        if not lines then return value(text, ranges, max_w) end
        if not source then return lines, nil end
        local runs = {}
        for row, offsets in ipairs(source) do
          local pieces, col = {}, 1
          for j = 1, #offsets, 2 do
            local next_col = col + offsets[j + 1]
            pieces[#pieces + 1] = { s = offsets[j], text = lines[row]:sub(col, next_col - 1) }
            col = next_col
          end
          runs[row] = spans.runs(pieces, ranges)
        end
        return lines, runs
      end)
      replaced = replaced + 1
    elseif type(value) == "function" then
      visit(value)
    end
  end
end
visit(require("fibrous.inline.layout").compute)
assert(replaced > 0, "benchmark could not install coalesced comparator")
