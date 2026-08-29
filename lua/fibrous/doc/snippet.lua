-- The ui.code component: a source snippet with treesitter highlighting, an
-- optional file-reference header, and a line-number gutter whose numbers
-- MATCH the referenced code. Exposed as `ui.code` via a lazy forwarder in
-- inline/components.lua (the markdown pattern), so importing the component
-- surface never pulls the highlighter onto the module graph.
--
-- Props:
--   code          the source text (required)
--   lang          treesitter language; defaults from ref.path via
--                 vim.filetype.match, degrading to plain @markup.raw when no
--                 parser resolves (the fenced-code rule)
--   ref           { path, start_line? } — what the snippet quotes. Drawn as a
--                 clickable header row, and start_line seeds the gutter so
--                 the numbers match the referenced file
--   start_line    gutter start without (or overriding) a ref (default 1)
--   line_numbers  the gutter (default true)
--   header        the reference row (default: shown when ref is present)
--   on_open       header activation, given the ref (default: edit the file at
--                 start_line — in the PREVIOUS window, because the click
--                 lands with the mount's own window current, and swapping the
--                 app's buffer out from under it is never what a jump means)
--   max_lines     cap rendered lines; a dim "… N more lines" marker follows
--
-- Layout/style props (style, grow, width, …) pass through to the outer col.

local highlight = require("fibrous.doc.highlight")
local ui = require("fibrous.inline.components")

local M = {}

-- Threaded onto the outer col, shared with ui.diff (the two components are
-- the same chrome around different bodies).
M.PASS = { "style", "grow", "width", "height", "min_width", "max_width", "align_self", "on_key" }

--- Copy the pass-through props onto `vnode` and return it.
---@param vnode table
---@param props table
---@return table
function M.pass(vnode, props)
  for _, k in ipairs(M.PASS) do
    if props[k] ~= nil then
      vnode.props[k] = props[k]
    end
  end
  return vnode
end

--- The language to highlight with: the explicit prop, else the filetype
--- resolved from ref.path (a snippet that knows its file knows its language).
---@param props { lang?: string, ref?: { path?: string } }
---@return string|nil
function M.lang_of(props)
  if props.lang ~= nil then
    return props.lang
  end
  local path = props.ref and props.ref.path
  if not path then
    return nil
  end
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  return ok and ft or nil
end

--- Default header activation: open the ref in the PREVIOUS window (see the
--- header comment) and land on its start line.
---@param ref { path: string, start_line?: integer }
function M.open_ref(ref)
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  vim.cmd.edit(vim.fn.fnameescape(ref.path))
  if ref.start_line then
    pcall(vim.api.nvim_win_set_cursor, 0, { ref.start_line, 0 })
  end
end

--- "path:12-34" — the range covers the whole snippet, and appears only when
--- the start is known (a range counted from 1 on an unanchored snippet would
--- claim line numbers the file doesn't have). Nil when there is no ref, or
--- header = false.
---@param props table ui.code props
---@param nlines integer
---@return string|nil
function M.header_label(props, nlines)
  local ref = props.ref
  if not ref or props.header == false then
    return nil
  end
  local label = ref.path or ""
  local start = ref.start_line or props.start_line
  if start then
    label = nlines > 1 and ("%s:%d-%d"):format(label, start, start + nlines - 1)
      or ("%s:%d"):format(label, start)
  end
  return label
end

--- The header row: one interactive span, dim at rest, link-accented on hover
--- — the same span machinery markdown links ride, so it hovers, clicks and
--- flash-jumps like one.
---@param props table ui.code props
---@param nlines integer
---@return table|nil vnode
function M.header(props, nlines)
  local label = M.header_label(props, nlines)
  if not label then
    return nil
  end
  local ref = props.ref
  local open = props.on_open or M.open_ref
  return {
    comp = ui.label,
    props = {
      text = {
        {
          label,
          role = "link",
          on_click = function()
            open(ref)
          end,
          style = { text_hl = "FibrousDim", _hover = { text_hl = "@markup.link" } },
        },
      },
    },
  }
end

--- The gutter column: `shown` right-aligned numbers from `start`, padded to
--- the width of the snippet's LAST number so truncation never changes
--- alignment mid-scroll.
---@param start integer
---@param shown integer
---@param last integer the final number of the full (untruncated) snippet
---@return string
local function gutter_text(start, shown, last)
  local width = #tostring(last)
  local out = {}
  for i = 0, shown - 1 do
    out[#out + 1] = ("%" .. width .. "d"):format(start + i)
  end
  return table.concat(out, "\n")
end

--- Re-join per-line span lists into one text-node span list, lines 1..shown.
---@param lines table[][]
---@param shown integer
---@return table[]
local function join_spans(lines, shown)
  local spans = {}
  for i = 1, shown do
    if i > 1 then
      spans[#spans + 1] = "\n"
    end
    for _, s in ipairs(lines[i] or {}) do
      spans[#spans + 1] = s
    end
  end
  return spans
end

--- The ui.code body. Stateful only for the highlight memo: highlight.code
--- caches the flat spans, but the per-line reshape runs per call, so the
--- component keeps its own (code, lang) → lines ref across re-renders.
---@param ctx table
---@param props table
---@return table vnode
function M.component(ctx, props)
  local code = props.code or ""
  local lines = vim.split(code, "\n", { plain = true })
  local lang = M.lang_of(props)
  local start = props.start_line or (props.ref and props.ref.start_line) or 1
  local shown = #lines
  if props.max_lines and props.max_lines < shown then
    shown = props.max_lines
  end

  local memo = ctx.use_ref()
  local m = memo.current
  if not m or m.code ~= code or m.lang ~= lang then
    m = { code = code, lang = lang, lines = highlight.code_lines(code, lang) }
    memo.current = m
  end

  local body
  if m.lines then
    body = { comp = ui.text, props = { text = join_spans(m.lines, shown), wrap = false } }
  else
    body = {
      comp = ui.text,
      props = {
        text = table.concat(lines, "\n", 1, shown),
        wrap = false,
        style = { text_hl = "@markup.raw" },
      },
    }
  end

  local content = body
  if props.line_numbers ~= false then
    content = {
      comp = ui.row,
      props = { gap = 1 },
      children = {
        {
          comp = ui.text,
          props = {
            text = gutter_text(start, shown, start + #lines - 1),
            wrap = false,
            style = { text_hl = "FibrousCodeGutter" },
          },
        },
        body,
      },
    }
  end

  local rows = {}
  rows[#rows + 1] = M.header(props, #lines)
  rows[#rows + 1] = content
  if shown < #lines then
    rows[#rows + 1] = {
      comp = ui.label,
      props = {
        text = ("… %d more lines"):format(#lines - shown),
        style = { text_hl = "FibrousDim" },
      },
    }
  end

  return M.pass({ comp = ui.col, props = {}, children = rows }, props)
end

return M
