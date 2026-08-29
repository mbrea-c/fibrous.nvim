-- The ui.diff component: a unified diff with syntax highlighting UNDER the
-- Diff* line fills, a dual old│new line-number gutter, and context folded
-- around the hunks. Exposed as `ui.diff` via a lazy forwarder in
-- inline/components.lua (the markdown pattern).
--
-- Two input shapes:
--   before/after  the two sides' CONTENT; vim.diff (xdiff) finds the hunks.
--                 Each side is highlighted ONCE as a whole — the string
--                 parser sees real surrounding code, not per-line fragments —
--                 then split per line and interleaved.
--   unified       an already-formatted unified diff (git, an agent). The
--                 hunk headers give the numbering; the sides are
--                 reconstructed from the +/-/context lines for highlighting.
--
-- Line fills do the add/delete colouring: each changed row's text node
-- carries `style.hl = DiffAdd/DiffDelete`, and hlmix composes the fg-only
-- syntax spans over that fill — fg-syntax on bg-diff, no combined groups to
-- define. Shares ui.code's header/pass-through chrome (fibrous.doc.snippet).
--
-- Props: before/after | unified, lang (else from ref.path), ref
-- { path, start_line? }, start_line (shifts BOTH sides' numbers; with
-- `unified` the hunk headers are already absolute, so leave it unset),
-- context (default 3), line_numbers (default true; false keeps the sign
-- column), header (default: shown when ref is present), on_open, max_lines,
-- plus the shared layout/style pass-through.

local highlight = require("fibrous.doc.highlight")
local snippet = require("fibrous.doc.snippet")
local ui = require("fibrous.inline.components")

local M = {}

local xdiff = vim.text and vim.text.diff or vim.diff

--- Rows from the two sides' content, via xdiff index hunks. Emits raw
--- (1-based, unshifted) numbers; build() applies the start_line offset.
--- `old_no`/`new_no` double as the index into the side's line array, which is
--- what the component looks highlighted lines up by.
---@param before string
---@param after string
---@param ctx_n integer context lines around each hunk
---@return table[] rows, string[] a, string[] b
local function rows_from_sides(before, after, ctx_n)
  local a = vim.split(before or "", "\n", { plain = true })
  local b = vim.split(after or "", "\n", { plain = true })
  local hunks = xdiff(before or "", after or "", { result_type = "indices" }) or {}
  local rows = {}
  if #hunks == 0 then
    return rows, a, b
  end

  local last_a = 0 -- a-lines consumed so far (context or deletion)
  local drift = 0 -- new_no - old_no across the aligned region after last hunk
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- count == 0 marks a pure insertion/deletion: the start index is then the
    -- line BEFORE the change on that side, not the first changed line.
    local a_from = ca == 0 and sa + 1 or sa
    local b_from = cb == 0 and sb + 1 or sb

    -- The unchanged gap up to this hunk: all of it when it fits inside the
    -- two context windows, else the previous hunk's trailing lines, one skip
    -- row for the fold, and this hunk's leading lines. At the document start
    -- there is no previous hunk, so no trailing window.
    local gap_to = a_from - 1
    local lead_from = math.max(last_a + 1, a_from - ctx_n)
    local trail_to = last_a == 0 and 0 or math.min(gap_to, last_a + ctx_n)
    for i = last_a + 1, gap_to do
      if i <= trail_to or i >= lead_from then
        rows[#rows + 1] = { kind = "ctx", old_no = i, new_no = i + drift, text = a[i] }
      elseif i == trail_to + 1 then
        rows[#rows + 1] = { kind = "skip", count = lead_from - trail_to - 1 }
      end
    end

    for i = sa, sa + ca - 1 do
      rows[#rows + 1] = { kind = "del", old_no = i, text = a[i] }
    end
    for j = sb, sb + cb - 1 do
      rows[#rows + 1] = { kind = "add", new_no = j, text = b[j] }
    end

    last_a = a_from - 1 + ca
    drift = (b_from - 1 + cb) - last_a
  end

  local tail_to = math.min(#a, last_a + ctx_n)
  for i = last_a + 1, tail_to do
    rows[#rows + 1] = { kind = "ctx", old_no = i, new_no = i + drift, text = a[i] }
  end
  if tail_to < #a then
    rows[#rows + 1] = { kind = "skip", count = #a - tail_to }
  end
  return rows, a, b
end

--- Rows from a unified diff text. The hunk headers carry ABSOLUTE numbers,
--- which go straight onto the rows; the sides are reconstructed (in raw
--- index order, `old_idx`/`new_idx`) so highlight lookup still works. A skip
--- row (of unknown count) separates hunks. Anything before the first @@ (git
--- file headers) and "\ No newline…" markers are ignored.
---@param unified string
---@return table[] rows, string[] a, string[] b
local function rows_from_unified(unified)
  local rows = {}
  local a, b = {}, {}
  local old_no, new_no
  local lines = vim.split(unified or "", "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines) -- the trailing newline is not an empty context line
  end
  for _, line in ipairs(lines) do
    local oh, nh = line:match("^@@ %-(%d+)[,%d]* %+(%d+)[,%d]* @@")
    if oh then
      if old_no then
        rows[#rows + 1] = { kind = "skip" }
      end
      old_no, new_no = tonumber(oh), tonumber(nh)
    elseif old_no then
      local c, rest = line:sub(1, 1), line:sub(2)
      if c == "-" then
        a[#a + 1] = rest
        rows[#rows + 1] = { kind = "del", old_no = old_no, text = rest, old_idx = #a }
        old_no = old_no + 1
      elseif c == "+" then
        b[#b + 1] = rest
        rows[#rows + 1] = { kind = "add", new_no = new_no, text = rest, new_idx = #b }
        new_no = new_no + 1
      elseif c == " " or line == "" then
        a[#a + 1] = rest
        b[#b + 1] = rest
        rows[#rows + 1] =
          { kind = "ctx", old_no = old_no, new_no = new_no, text = rest, old_idx = #a, new_idx = #b }
        old_no = old_no + 1
        new_no = new_no + 1
      end
      -- anything else ("\ No newline at end of file"): skipped
    end
  end
  return rows, a, b
end

--- Assemble the row model: kind ("ctx"/"add"/"del"/"skip"), display numbers
--- (old_no/new_no, start_line applied), the line's text, and the raw index
--- into each side (old_idx/new_idx) for highlight lookup. Pure in props —
--- the component memoizes around it.
---@param props table ui.diff props
---@return table[] rows, string[] a, string[] b
function M.build(props)
  local rows, a, b
  if props.unified then
    rows, a, b = rows_from_unified(props.unified)
  else
    rows, a, b = rows_from_sides(props.before, props.after, props.context or 3)
    for _, r in ipairs(rows) do
      r.old_idx, r.new_idx = r.old_no, r.new_no
    end
  end
  local off = (props.start_line or 1) - 1
  if off ~= 0 then
    for _, r in ipairs(rows) do
      r.old_no = r.old_no and r.old_no + off
      r.new_no = r.new_no and r.new_no + off
    end
  end
  return rows, a, b
end

local SIGN = { add = "+", del = "-", ctx = " " }
local SIGN_HL = { add = "Added", del = "Removed" }
local FILL = { add = "DiffAdd", del = "DiffDelete" }

--- The ui.diff body. Stateful only for the memo: rows + per-line highlights
--- are pure in (before, after, unified, lang, context, start_line), and a
--- transcript re-renders far more often than a diff changes.
---@param ctx table
---@param props table
---@return table vnode
function M.component(ctx, props)
  local lang = snippet.lang_of(props)
  local memo = ctx.use_ref()
  local m = memo.current
  if
    not m
    or m.before ~= props.before
    or m.after ~= props.after
    or m.unified ~= props.unified
    or m.lang ~= lang
    or m.context ~= props.context
    or m.start_line ~= props.start_line
  then
    local rows, a, b = M.build(props)
    m = {
      before = props.before,
      after = props.after,
      unified = props.unified,
      lang = lang,
      context = props.context,
      start_line = props.start_line,
      rows = rows,
      hl_old = lang and highlight.code_lines(table.concat(a, "\n"), lang) or nil,
      hl_new = lang and highlight.code_lines(table.concat(b, "\n"), lang) or nil,
    }
    memo.current = m
  end

  -- Gutter widths from the widest DISPLAY number on each side, so the two
  -- columns stay aligned over every row.
  local wo, wn = 1, 1
  for _, r in ipairs(m.rows) do
    wo = math.max(wo, r.old_no and #tostring(r.old_no) or 1)
    wn = math.max(wn, r.new_no and #tostring(r.new_no) or 1)
  end
  local num_fmt = "%" .. wo .. "s %" .. wn .. "s"

  local children = {}
  children[#children + 1] = snippet.header(props, 0)

  local shown = 0
  for _, r in ipairs(m.rows) do
    if props.max_lines and shown >= props.max_lines then
      children[#children + 1] = {
        comp = ui.label,
        props = { text = "… diff truncated", style = { text_hl = "FibrousDim" } },
      }
      break
    end
    if r.kind == "skip" then
      children[#children + 1] = {
        comp = ui.label,
        props = {
          text = r.count and ("⋯ %d unchanged lines"):format(r.count) or "⋯",
          style = { text_hl = "FibrousDim" },
        },
      }
    else
      shown = shown + 1
      local gutter = {}
      if props.line_numbers ~= false then
        gutter[#gutter + 1] = {
          num_fmt:format(r.old_no or "", r.new_no or ""),
          hl = "FibrousCodeGutter",
        }
        gutter[#gutter + 1] = { " " .. SIGN[r.kind] .. " ", hl = SIGN_HL[r.kind] }
      else
        gutter[#gutter + 1] = { SIGN[r.kind] .. " ", hl = SIGN_HL[r.kind] }
      end

      -- The line's foreground: its side's syntax spans when highlighted,
      -- else the raw text. An empty line keeps one space so the fill has a
      -- cell to paint.
      local side = r.kind == "add" and m.hl_new or m.hl_old
      local idx = r.kind == "add" and r.new_idx or r.old_idx
      local text = side and idx and side[idx] or r.text or ""
      if (type(text) == "string" and text == "") or (type(text) == "table" and #text == 0) then
        text = " "
      end

      local fill = FILL[r.kind]
      children[#children + 1] = {
        comp = ui.row,
        props = {},
        children = {
          { comp = ui.label, props = { text = gutter } },
          {
            comp = ui.text,
            props = { text = text, wrap = false, style = fill and { hl = fill } or nil },
          },
        },
      }
    end
  end

  if shown == 0 then
    children[#children + 1] = {
      comp = ui.label,
      props = { text = "(no changes)", style = { text_hl = "FibrousDim" } },
    }
  end

  return snippet.pass({ comp = ui.col, props = {}, children = children }, props)
end

return M
