-- The format-neutral document AST. This is the CONTRACT between any parser
-- (fibrous.markdown today; org/asciidoc/structured-content tomorrow) and the
-- shared renderer (fibrous.doc.render). It is deliberately semantic, not
-- syntactic: nodes describe what a document MEANS (a heading, a link, a code
-- block), never how a particular source spelled it. Keeping one neutral tree,
-- rather than a markdown-specific tree plus a converter, is what lets a second
-- format reuse the renderer by emitting these same nodes.
--
-- A node is a plain table with a string `type` and type-specific fields. Block
-- nodes carry `children` (or `items`/`rows`); inline nodes carry `children` or
-- a `text`. The constructors below just stamp the shape so parsers stay honest.

local M = {}

-- ── inline ──────────────────────────────────────────────────────────────────

---@param text string
function M.text(text)
  return { type = "text", text = text }
end

---@param text string  the literal code, no backticks
function M.code_span(text)
  return { type = "code_span", text = text }
end

---@param children table[]
function M.strong(children)
  return { type = "strong", children = children }
end

---@param children table[]
function M.emph(children)
  return { type = "emph", children = children }
end

---@param children table[]
function M.strikethrough(children)
  return { type = "strikethrough", children = children }
end

---@param url string
---@param title string|nil
---@param children table[]  the link's visible inline content
function M.link(url, title, children)
  return { type = "link", url = url, title = title, children = children }
end

---@param url string
---@param alt string       the alt text (images render as their alt in a terminal)
---@param title string|nil
function M.image(url, alt, title)
  return { type = "image", url = url, alt = alt, title = title }
end

-- A soft line break in the source (rendered as a space or a wrap point).
function M.softbreak()
  return { type = "softbreak" }
end

-- A hard line break (two trailing spaces / backslash): forces a new line.
function M.hardbreak()
  return { type = "hardbreak" }
end

-- ── blocks ──────────────────────────────────────────────────────────────────

---@param level integer  1..6
---@param children table[]  inline content
function M.heading(level, children)
  return { type = "heading", level = level, children = children }
end

---@param children table[]  inline content
function M.paragraph(children)
  return { type = "paragraph", children = children }
end

---@param lang string|nil  fenced-code info string (language), or nil
---@param text string      the code body (no fences)
function M.code_block(lang, text)
  return { type = "code_block", lang = lang, text = text }
end

---@param children table[]  block content
function M.blockquote(children)
  return { type = "blockquote", children = children }
end

function M.thematic_break()
  return { type = "thematic_break" }
end

---@param children table[]  block content of the item
---@param checked boolean|nil  nil = a plain item; true/false = a task item
function M.list_item(children, checked)
  return { type = "list_item", children = children, checked = checked }
end

---@param opts { ordered: boolean, start?: integer, tight?: boolean, items: table[] }
function M.list(opts)
  return {
    type = "list",
    ordered = opts.ordered or false,
    start = opts.start,
    tight = opts.tight or false,
    items = opts.items or {},
  }
end

---@param opts { align: (string|nil)[], header: table[][], rows: table[][][] }
--- align[i] is "left"|"center"|"right"|nil; header[i] and rows[r][i] are inline lists.
function M.table(opts)
  return { type = "table", align = opts.align or {}, header = opts.header or {}, rows = opts.rows or {} }
end

---@param children table[]  top-level blocks
function M.document(children)
  return { type = "document", children = children }
end

return M
