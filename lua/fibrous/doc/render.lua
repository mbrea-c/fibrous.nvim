-- The shared document renderer: a format-neutral document AST (fibrous.doc.ast)
-- to fibrous vnodes. This is the ONLY module that knows about ui.* primitives,
-- so every format that emits the AST renders through here for free.
--
-- Blocks map onto the flex primitives (col/paragraph/text/container); inline
-- marks map onto Neovim's standard @markup.* highlight groups, so the output
-- inherits the user's colorscheme markup styling and the fibrous theme can
-- override. Links become INTERACTIVE spans (role = "link" + on_click), which
-- makes them hover/click/flash targets through the span machinery.
--
-- opts:
--   on_link(url)              fired when a link span is activated; defaults to
--                             vim.ui.open (falls back to a notify)
--   highlight(text, lang)     optional fenced-code highlighter → span list; the
--                             default renders code plain (@markup.raw), so the
--                             widget stays dependency-free (and WASM-safe)

local ui = require("fibrous.inline.components")

local M = {}

-- ── inline ────────────────────────────────────────────────────────────────

-- Shallow-copy `ctx` with `over` applied — the inline walk threads a styling /
-- interaction context down the mark tree, innermost wins (one hl per run).
local function merge(ctx, over)
  local out = {}
  for k, v in pairs(ctx) do
    out[k] = v
  end
  for k, v in pairs(over) do
    out[k] = v
  end
  return out
end

-- A span for `text` under the current context: a bare string when nothing
-- styles or handles it, else a SpanStyle/interaction table.
local function span(text, ctx)
  if not ctx.text_hl and not ctx.hover_hl and not ctx.on_click and not ctx.role then
    return text
  end
  local sp = { text }
  if ctx.text_hl or ctx.hover_hl then
    sp.style = {}
    sp.style.text_hl = ctx.text_hl
    if ctx.hover_hl then
      sp.style._hover = { text_hl = ctx.hover_hl }
    end
  end
  sp.on_click = ctx.on_click
  sp.role = ctx.role
  return sp
end

local function default_open(url)
  if vim.ui and vim.ui.open then
    pcall(vim.ui.open, url)
  else
    vim.notify("fibrous.markdown: open " .. tostring(url))
  end
end

local MARK_HL = {
  strong = "@markup.strong",
  emph = "@markup.italic",
  strikethrough = "@markup.strikethrough",
}

local function walk_inline(nodes, ctx, opts, out)
  for _, n in ipairs(nodes) do
    local t = n.type
    if t == "text" then
      out[#out + 1] = span(n.text, ctx)
    elseif t == "code_span" then
      out[#out + 1] = span(n.text, merge(ctx, { text_hl = "@markup.raw" }))
    elseif t == "softbreak" or t == "hardbreak" then
      -- both collapse to a space: a paragraph is one wrapping text node, so the
      -- break becomes a wrap opportunity rather than a forced newline (v1).
      out[#out + 1] = " "
    elseif MARK_HL[t] then
      walk_inline(n.children, merge(ctx, { text_hl = MARK_HL[t] }), opts, out)
    elseif t == "link" then
      local url = n.url
      walk_inline(
        n.children,
        merge(ctx, {
          text_hl = "@markup.link",
          role = "link",
          on_click = function()
            (opts.on_link or default_open)(url)
          end,
        }),
        opts,
        out
      )
    elseif t == "image" then
      -- a terminal shows the alt text; keep it visually link-like
      local alt = (n.alt and n.alt ~= "") and n.alt or (n.url or "image")
      out[#out + 1] = span(alt, merge(ctx, { text_hl = "@markup.link" }))
    end
  end
end

-- Render a list of inline nodes to a fibrous span list.
---@param nodes table[]
---@param opts table
---@return table[] spans
function M.inline(nodes, opts)
  local out = {}
  walk_inline(nodes, {}, opts or {}, out)
  return out
end

-- ── blocks ──────────────────────────────────────────────────────────────────

local render_block, render_blocks

local function heading_hl(level)
  return "@markup.heading." .. math.max(1, math.min(level or 1, 6))
end

local function render_list(node, opts)
  local rows = {}
  for i, item in ipairs(node.items) do
    local marker
    if item.checked ~= nil then
      marker = { comp = ui.checkbox, props = { label = "", checked = item.checked, theme = false } }
    elseif node.ordered then
      marker = { comp = ui.label, props = { text = ((node.start or 1) + i - 1) .. ". " } }
    else
      marker = { comp = ui.label, props = { text = "• ", style = { text_hl = "@markup.list" } } }
    end
    rows[#rows + 1] = {
      comp = ui.row,
      props = { gap = item.checked ~= nil and 1 or 0, align = "start" },
      children = {
        marker,
        {
          comp = ui.col,
          props = { gap = node.tight and 0 or 1, grow = 1 },
          children = render_blocks(item.children, opts),
        },
      },
    }
  end
  return { comp = ui.col, props = { gap = node.tight and 0 or 1 }, children = rows }
end

function render_block(node, opts)
  local t = node.type
  if t == "paragraph" then
    return { comp = ui.paragraph, props = { text = M.inline(node.children, opts) } }
  elseif t == "heading" then
    return {
      comp = ui.paragraph,
      props = { text = M.inline(node.children, opts), style = { text_hl = heading_hl(node.level) } },
    }
  elseif t == "code_block" then
    local text = node.text
    if opts.highlight then
      local ok, spans = pcall(opts.highlight, text, node.lang)
      if ok and spans then
        return { comp = ui.text, props = { text = spans, wrap = false } }
      end
    end
    return { comp = ui.text, props = { text = text, wrap = false, style = { text_hl = "@markup.raw" } } }
  elseif t == "blockquote" then
    return {
      comp = ui.col,
      props = {
        gap = 1,
        style = { border = { left = true, hl = "@markup.quote" }, padding = { left = 1 } },
      },
      children = render_blocks(node.children, opts),
    }
  elseif t == "thematic_break" then
    return { comp = ui.col, props = { style = { border = { top = true, hl = "NonText" } } } }
  elseif t == "list" then
    return render_list(node, opts)
  elseif t == "table" then
    return require("fibrous.doc.table").render(node, opts)
  end
  -- unknown block: render nothing rather than error
  return { comp = ui.col, props = {} }
end

function render_blocks(nodes, opts)
  local out = {}
  for _, n in ipairs(nodes) do
    out[#out + 1] = render_block(n, opts)
  end
  return out
end

-- Render a document (or any single block) to a fibrous vnode.
---@param node table  a fibrous.doc.ast node
---@param opts? { on_link?: fun(url: string), highlight?: fun(text: string, lang: string|nil): table }
---@return table vnode
function M.render(node, opts)
  opts = opts or {}
  if node.type == "document" then
    return { comp = ui.col, props = { gap = 1 }, children = render_blocks(node.children, opts) }
  end
  return render_block(node, opts)
end

return M
