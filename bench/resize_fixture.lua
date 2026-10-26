-- Shared resize scenes. The harness stays fixed while lua/fibrous/ varies.
local ui = require("fibrous.inline.components")
local markdown = dofile((debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./") .. "markdown_fixture.lua")
local M = { widths = { 100, 99, 96, 92, 84, 76, 64, 65, 70, 78, 88, 96 } }
local prose = "A paragraph with several ordinary words, styled spans, and a longer_identifier_to_wrap across widths."
local function paragraph(i)
  return { comp = ui.paragraph, props = { text = {
    { ("Section %d: "):format(i), hl = "Title" },
    prose, { " follow this link", hl = "Underlined", role = "link", on_click = function() end },
    i % 7 == 0 and " 界面 café é" or "",
  } } }
end

function M.scene(kind, n)
  if kind == "markdown" then
    local text = markdown.document(n)
    return function()
      return { comp = ui.markdown, props = { text = text, source = { id = "resize", text = text } } }
    end
  end
  local entries = {}
  for i = 1, n do
    if kind == "clamped" then
      entries[i] = { comp = ui.col, props = { max_width = 48, style = { padding = { x = 1 } } },
        children = { paragraph(i) } }
    else
      local content = { paragraph(i),
        { comp = ui.label, props = { text = ("status %d: unchanged"):format(i), style = { text_hl = "Comment" } } } }
      if i % 15 == 0 then
        content[#content + 1] = { comp = ui.text, props = {
          text = "  local result = 界面 + café -- preserve indentation and spaces",
          wrap = "char", style = { text_hl = "String" } } }
      end
      if i % 25 == 0 then
        content[#content + 1] = { comp = ui.container, props = { height = 3,
          style = { border = "rounded", padding = { x = 1 } } }, children = {
            { comp = ui.paragraph, props = { text = prose } },
            { comp = ui.label, props = { text = "separate scrollable output" } },
          } }
      end
      entries[i] = { comp = ui.col, props = {
        style = i % 10 == 0 and { border = "single", padding = { x = 1 } } or nil,
      }, children = content }
    end
  end
  local main = { comp = ui.col, props = { grow = 1 }, children = entries }
  if kind == "clamped" then return function() return main end end
  local sidebar = {}
  for i = 1, math.max(1, math.floor(n / 5)) do
    sidebar[i] = { comp = ui.paragraph, props = { text = ("Fixed-width item %d with some details"):format(i) } }
  end
  return function()
    return { comp = ui.row, props = { gap = 1 }, children = {
      { comp = ui.col, props = { width = 24, style = { border = "single", padding = { x = 1 } } },
        children = sidebar },
      main,
    } }
  end
end

function M.fingerprint(host)
  local frames = {}
  local function visit(target)
    local marks = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target.bufnr, -1, 0, -1, { details = true })) do
      local d = mark[4]
      if d.hl_group then marks[#marks + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group } end
    end
    table.sort(marks, function(a, b) return vim.json.encode(a) < vim.json.encode(b) end)
    frames[#frames + 1] = vim.json.encode({
      vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false), marks,
    })
    for _, node in ipairs(target.subwins or {}) do
      if node.inner then visit(host.targets[node.fiber]) end
    end
  end
  visit(host.root_target)
  return vim.fn.sha256(table.concat(frames))
end

return M
