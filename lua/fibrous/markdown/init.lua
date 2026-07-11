-- fibrous.markdown: the public parse entry. Orchestrates the two phases (block
-- structure, then inline within each leaf) and lowers the raw block tree into
-- the format-neutral document AST (fibrous.doc.ast) that the shared renderer
-- consumes. Pure Lua, no treesitter, so it runs everywhere fibrous does
-- (including the WASM docs site).

local ast = require("fibrous.doc.ast")
local block = require("fibrous.markdown.block")
local inline = require("fibrous.markdown.inline")

local M = {}

local convert_blocks

local function convert(raw)
  local k = raw.kind
  if k == "heading" then
    return ast.heading(raw.level, inline.parse(raw.text))
  elseif k == "paragraph" then
    return ast.paragraph(inline.parse(raw.text))
  elseif k == "code_block" then
    return ast.code_block(raw.lang, raw.text)
  elseif k == "thematic_break" then
    return ast.thematic_break()
  elseif k == "math" then
    return ast.math_block(raw.tex)
  elseif k == "blockquote" then
    return ast.blockquote(convert_blocks(raw.blocks))
  elseif k == "list" then
    local items = {}
    for _, it in ipairs(raw.items) do
      items[#items + 1] = ast.list_item(convert_blocks(it.blocks), it.checked)
    end
    return ast.list({ ordered = raw.ordered, start = raw.start, tight = raw.tight, items = items })
  elseif k == "table" then
    local function cells(row)
      local out = {}
      for _, c in ipairs(row) do
        out[#out + 1] = inline.parse(c)
      end
      return out
    end
    local rows = {}
    for _, r in ipairs(raw.rows) do
      rows[#rows + 1] = cells(r)
    end
    return ast.table({ align = raw.align, header = cells(raw.header), rows = rows })
  end
  return ast.paragraph({})
end

function convert_blocks(raws)
  local out = {}
  for _, r in ipairs(raws) do
    out[#out + 1] = convert(r)
  end
  return out
end

-- Parse markdown source into a fibrous.doc.ast document.
---@param text string
---@param _opts? table  reserved (reference definitions, GFM toggles, …)
---@return table document
function M.parse(text, _opts)
  return ast.document(convert_blocks(block.parse(text or "")))
end

return M
