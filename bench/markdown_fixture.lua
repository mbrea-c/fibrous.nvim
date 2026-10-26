-- Shared, deterministic input for the Markdown CPU and real-PTY experiments.
local M = {}

local SECTION = table.concat({
  "## Section %d", "",
  "Some **bold** and *emphasis* with `inline code` and a [link](http://example.com/%d) inline.", "",
  "- first point", "- second point with `code`", "- [x] a finished task", "",
  "> a short blockquote about section %d and its details", "",
  "```lua", "local x = %d", "return x + 1", "```", "",
}, "\n")

function M.document(n)
  local out = {}
  for i = 1, n do out[i] = SECTION:format(i, i, i, i) end
  return table.concat(out, "\n")
end

function M.plain(n)
  return (("Ordinary prose with several words and no inline markup. "):rep(6) .. "\n\n"):rep(n)
end

function M.ranges(text, count)
  local out = {}
  for i = 1, count do
    local needle = "Section " .. i
    local at = assert(text:find(needle, 1, true))
    out[#out + 1] = { at - 1, at - 1 + #needle }
  end
  return out
end

return M
