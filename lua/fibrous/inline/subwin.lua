-- The subwindow manager (tracker "NEW UI HOST" tasks 4 + 7). Subwindow leaves
-- (text_input, raw_buffer) are laid out inline like everything else — their
-- border/background even paint in the root buffer — but their CONTENT box is
-- covered by a real float anchored to the root float, so the user gets a
-- native buffer to type into (text_input: an owned scratch buffer seeded from
-- props.value; raw_buffer: a caller-provided, UNOWNED props.bufnr, or an owned
-- scratch one without it).
--
-- Because relative="win" floats anchor to the window grid, not its scrolled
-- content, the manager subtracts the root's scroll offsets itself — topline
-- AND leftcol (the root is nowrap, so trackpads/zl can scroll it sideways) —
-- and resyncs on WinScrolled. Occlusion (tracker decision, clipping strategy;
-- the 4b eval verdict: no visible swim, clipping stays):
--   partial  — resize the float to its visible rows and re-anchor its own
--              viewport (topline) so the right slice of content shows;
--   full     — hide the float (nvim_win_set_config hide).
--
-- Focus traversal (task 7; explicit-focus rework): subwindows never capture
-- the cursor — the root cursor glides across their region like any other
-- cells. Focus is explicit:
--   in   `enter_at(row, x)` (exposed on the manager) focuses the float whose
--        rect contains that root-buffer cell, cursor translated (and clamped)
--        into its content. interact.lua drives it from <CR>, clicks, and the
--        insert-entry keys (i/I/a/A/o/O);
--   out  h/j/k/l at the float buffer's edge step into the root buffer adjacent
--        to the widget (keeping the cursor's row/col alignment); <C-w>-h/j/k/l
--        exit unconditionally; <C-d>/<C-u> always hand focus AND the motion to
--        the root — page motions are never trapped. Exits whose target falls
--        outside the root buffer are no-ops (staying put beats the root
--        clamping the cursor straight back into the widget).
--
-- text_input wiring: buffer edits report through props.on_change(value)
-- (TextChanged/TextChangedI); <CR> — normal or insert mode — calls
-- props.on_submit(value) when given, otherwise insert-mode <CR> falls through
-- to a plain newline. Handlers are read from the latest committed props at
-- fire time.

local width = require("fibrous.inline.width")
local cursorshim = require("fibrous.inline.cursorshim")

local M = {}

---@class SubwinManager
---@field sync fun()      reconcile floats against host.subwins and reposition them
---@field enter_at fun(row: integer, x: integer): boolean  focus the subwindow at root cell (row, x); false if none there
---@field teardown fun()  destroy all floats/buffers and the autocmds

---@param bufnr integer
---@return string
local function buf_value(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Render `line` the way the float displays it in a `w`-cell window: tabs
-- expand by logical virtual column to the next `ts` stop, and with `wrap` the
-- line chops into continuation rows at every w cells (a wide char straddling
-- the edge moves whole to the next row, like the display); without wrap it
-- truncates to one row. Rows are space-padded to exactly w. ('linebreak' and
-- horizontal scroll are not modeled — style="minimal" floats have neither.)
---@param line string
---@param w integer
---@param ts integer
---@param wrap boolean
---@return string[] rows  one per display row
local function chop(line, w, ts, wrap)
  local rows, out, cells, vcol = {}, {}, 0, 0
  local function flush_row()
    rows[#rows + 1] = table.concat(out) .. (" "):rep(w - cells)
    out, cells = {}, 0
  end
  for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local cw
    if ch == "\t" then
      cw = ts - (vcol % ts)
      ch = (" "):rep(cw)
    else
      cw = width.char(ch)
    end
    if cw > w then -- wider than the whole window: degrade to padding
      ch, cw = (" "):rep(w), w
    end
    if cells + cw > w then
      if not wrap then
        break
      end
      flush_row()
    end
    out[#out + 1] = ch
    cells = cells + cw
    vcol = vcol + cw
  end
  flush_row()
  return rows
end

-- Attach a manager to `host` (an InlineHost) whose buffer is shown in the
-- root float `root_winid`. The mount target calls this once, wires
-- `host.on_flush` to `sync`, and calls `teardown` on unmount.
---@param host InlineHost
---@param root_winid integer
---@return SubwinManager
function M.attach(host, root_winid)
  local group = vim.api.nvim_create_augroup("FibrousInlineSubwin_" .. root_winid, { clear = true })

  -- One float per live subwindow leaf, keyed by the fiber's host instance
  -- (stable across commits — the reconciler reuses it when the type matches).
  ---@type table<table, { bufnr: integer, winid: integer, node: table, owned: boolean, maps: table[] }>
  local floats = {}

  -- Per-component render policy (props.render):
  --   "focus" (default)  the float is hidden until explicitly focused; the
  --                      mirror + transcribed highlights ARE the widget. The
  --                      page stays flat text: honest block cursor, complete
  --                      visual-selection highlights, no guicursor shim.
  --   "always"           the float is always shown (live down to treesitter
  --                      fidelity); the mirror underneath is never seen and
  --                      needs no highlight work.
  local function policy(entry)
    local r = (entry.node.props or {}).render
    if r == "always" then
      return "always"
    end
    if r ~= nil and r ~= "focus" then
      error(('fibrous: invalid render policy %q (want "always" or "focus")'):format(tostring(r)))
    end
    return "focus"
  end

  -- Write the sub buffer's visible slice (topline `entry.base`, the widget's
  -- own scroll) into the root canvas cells of the content box. The float
  -- covers it when shown, so this is never LOOKED at then — it exists so the
  -- region is honest under a gliding cursor (real characters under the
  -- cursor, real text in yanks/selections) and it IS the view while a
  -- render="focus" widget is unfocused. The canvas repaints the box blank on
  -- every flush; sync() rewrites the mirror right after.
  local function mirror(entry)
    if not vim.api.nvim_buf_is_valid(host.bufnr) or not vim.api.nvim_buf_is_valid(entry.bufnr) then
      return
    end
    local c = entry.node.content
    if c.w <= 0 or c.h <= 0 then
      return
    end
    local base = entry.base or 1
    local ts = vim.bo[entry.bufnr].tabstop
    local wrap = vim.api.nvim_win_is_valid(entry.winid) and vim.wo[entry.winid].wrap or false

    -- Build the box's display rows starting at buffer line `base`, wrapping
    -- exactly like the float does; without wrap, a horizontal scroll
    -- (leftcol) shifts every row's window. `entry.mirror_map` records, per
    -- box row, which buffer line and starting cell it shows — the highlight
    -- transcriber translates sub-buffer positions through it.
    local leftcol = (not wrap and entry.leftcol) or 0
    local rows, map = {}, {}
    local count = vim.api.nvim_buf_line_count(entry.bufnr)
    local lnum = base
    while #rows < c.h and lnum <= count do
      local line = vim.api.nvim_buf_get_lines(entry.bufnr, lnum - 1, lnum, false)[1] or ""
      if wrap then
        for i, row in ipairs(chop(line, c.w, ts, true)) do
          if #rows >= c.h then
            break
          end
          rows[#rows + 1] = row
          map[#rows] = { lnum = lnum, cell0 = (i - 1) * c.w }
        end
      else
        -- render cells [leftcol, leftcol + w): chop wide enough, cut the
        -- prefix by display cells (a wide char straddling the cut pads left)
        local row = chop(line, leftcol + c.w, ts, false)[1]
        local slice = row:sub(width.cell_to_byte(row, leftcol) + 1)
        local d = width.str(slice)
        if d < c.w then
          slice = (" "):rep(c.w - d) .. slice
        end
        rows[#rows + 1] = slice
        map[#rows] = { lnum = lnum, cell0 = leftcol }
      end
      lnum = lnum + 1
    end
    while #rows < c.h do
      rows[#rows + 1] = (" "):rep(c.w)
    end
    entry.mirror_map = map

    local last = vim.api.nvim_buf_line_count(host.bufnr) - 1
    vim.bo[host.bufnr].modifiable = true
    for i = 0, c.h - 1 do
      local y = c.y + i
      if y >= 0 and y <= last then
        local root_line = vim.api.nvim_buf_get_lines(host.bufnr, y, y + 1, false)[1] or ""
        local b0 = width.cell_to_byte(root_line, c.x)
        local b1 = width.cell_to_byte(root_line, c.x + c.w)
        if b1 <= #root_line then
          vim.api.nvim_buf_set_text(host.bufnr, y, b0, y, b1, { rows[i + 1] })
        end
      end
    end
    vim.bo[host.bufnr].modifiable = false
  end

  -- Copy the sub buffer's queryable highlights onto the mirror region (only
  -- for render="focus", where the mirror is looked at). Two sources cover a
  -- typical buffer almost completely:
  --   * persistent extmarks — diagnostics, LSP semantic tokens, inlay-hint
  --     and plugin marks; anything nvim_buf_get_extmarks returns. hl_group
  --     spans translate through entry.mirror_map (wrap-aware).
  --   * regex :syntax — sampled per cell with synID when the buffer declares
  --     a syntax (b:current_syntax), compressed into runs.
  -- NOT copyable, by nvim design: ephemeral decoration-provider highlights
  -- (treesitter's, indent guides, ...) — they exist only during a redraw.
  -- Layout-changing features (conceal, inline virt_text, folds) are not
  -- modeled either; the mirror shows buffer text.
  local function transcribe(entry)
    local c = entry.node.content
    entry.ns = entry.ns or vim.api.nvim_create_namespace("fibrous_inline_mirror_" .. entry.winid)
    local last = vim.api.nvim_buf_line_count(host.bufnr) - 1
    -- Clear the WHOLE namespace, not just the box rows: every canvas flush
    -- is a full set_lines that RELOCATES existing marks out of the box,
    -- where a ranged clear would miss them forever — they accumulate by the
    -- hundreds per flush and frame times grow linearly.
    vim.api.nvim_buf_clear_namespace(host.bufnr, entry.ns, 0, -1)
    local map = entry.mirror_map or {}
    local ts = vim.bo[entry.bufnr].tabstop
    local syn = vim.b[entry.bufnr].current_syntax

    -- synID sampling costs milliseconds per widget: cache whole-line runs
    -- keyed by changedtick + syntax name, so flush frames over an unchanged
    -- buffer only re-place extmarks. Runs are absolute cells over the full
    -- line (window-independent): wrap continuation rows and later
    -- repositions all reuse them.
    local tick = vim.api.nvim_buf_get_changedtick(entry.bufnr)
    local cache = entry.syn_cache
    if not cache or cache.tick ~= tick or cache.syntax ~= syn then
      cache = { tick = tick, syntax = syn, rows = {} }
      entry.syn_cache = cache
    end
    local function syn_runs(lnum, sline)
      local runs = cache.rows[lnum]
      if runs then
        return runs
      end
      runs = {}
      vim.api.nvim_buf_call(entry.bufnr, function()
        local byte, cell = 1, 0
        local run_hl, run_s = nil, 0
        for ch in sline:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          local cw = ch == "\t" and (ts - (cell % ts)) or width.char(ch)
          local id = vim.fn.synID(lnum, byte, 1)
          local name = id ~= 0 and vim.fn.synIDattr(vim.fn.synIDtrans(id), "name") or nil
          if name == "" then
            name = nil
          end
          if name ~= run_hl then
            if run_hl then
              runs[#runs + 1] = { s = run_s, e = cell, hl = run_hl }
            end
            run_hl, run_s = name, cell
          end
          byte = byte + #ch
          cell = cell + cw
        end
        if run_hl then
          runs[#runs + 1] = { s = run_s, e = cell, hl = run_hl }
        end
      end)
      cache.rows[lnum] = runs
      return runs
    end

    -- One hl span at box row `i` (1-based), box-relative cells [s, e).
    local function mark(i, s, e, hl, prio)
      local y = c.y + i - 1
      if y < 0 or y > last or s >= e then
        return
      end
      local root_line = vim.api.nvim_buf_get_lines(host.bufnr, y, y + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(host.bufnr, entry.ns, y, width.cell_to_byte(root_line, c.x + s), {
        end_col = width.cell_to_byte(root_line, c.x + e),
        hl_group = hl,
        priority = prio,
      })
    end

    for i = 1, c.h do
      local m = map[i]
      if m then
        local sline = vim.api.nvim_buf_get_lines(entry.bufnr, m.lnum - 1, m.lnum, false)[1] or ""

        for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(entry.bufnr, -1, { m.lnum - 1, 0 }, { m.lnum - 1, -1 }, { details = true, overlap = true })) do
          local d = mk[4]
          if d.hl_group then
            -- clamp a (possibly multi-line) span to this buffer line, in cells
            local s_byte = mk[2] < m.lnum - 1 and 0 or mk[3]
            local e_byte = (d.end_row or mk[2]) > m.lnum - 1 and #sline or (d.end_col or mk[3])
            local s_cell = math.max(width.str(sline:sub(1, s_byte)), m.cell0)
            local e_cell = math.min(width.str(sline:sub(1, e_byte)), m.cell0 + c.w)
            -- +8: above the canvas's base spans (4096) without reordering
            -- the copied marks relative to each other
            mark(i, s_cell - m.cell0, e_cell - m.cell0, d.hl_group, (d.priority or 4096) + 8)
          end
        end

        if syn then
          for _, run in ipairs(syn_runs(m.lnum, sline)) do
            local s = math.max(run.s, m.cell0)
            local e = math.min(run.e, m.cell0 + c.w)
            if s < e then
              mark(i, s - m.cell0, e - m.cell0, run.hl, 4100)
            end
          end
        end
      end
    end
  end

  -- Place `entry`'s float over the visible slice of its content box, given
  -- the root's current scroll position. `fresh` means the canvas was just
  -- rewritten (a flush frame): the mirror under the box is blank again and
  -- must be re-extracted no matter what.
  local function reposition(entry, fresh)
    if not (vim.api.nvim_win_is_valid(root_winid) and vim.api.nvim_win_is_valid(entry.winid)) then
      return
    end
    local c = entry.node.content
    -- The root scrolls both ways (it is nowrap, so a trackpad/zl can move
    -- leftcol): the float offsets by topline AND leftcol, clipping on both
    -- axes symmetrically.
    local rv
    vim.api.nvim_win_call(root_winid, function()
      rv = vim.fn.winsaveview()
    end)
    local top_off = rv.topline - 1
    local left_off = rv.leftcol or 0
    local view_h = vim.api.nvim_win_get_height(root_winid)
    local view_w = vim.api.nvim_win_get_width(root_winid)
    local y0 = c.y - top_off
    local y1 = y0 + c.h - 1
    local vis_top, vis_bot = math.max(y0, 0), math.min(y1, view_h - 1)
    local x0 = c.x - left_off
    local x1 = x0 + c.w - 1
    local vis_left, vis_right = math.max(x0, 0), math.min(x1, view_w - 1)

    -- The widget may have scroll state of its own (an editor taller than its
    -- window). Capture its view BEFORE the resize below: shrinking a window
    -- makes nvim re-anchor topline around the cursor, which would pollute
    -- the reconstruction. `base` is the widget's own scroll = the displayed
    -- topline minus the clip we last applied (entry.clip).
    local focused = entry.winid == vim.api.nvim_get_current_win()
    local v, base
    if not focused then
      vim.api.nvim_win_call(entry.winid, function()
        v = vim.fn.winsaveview()
      end)
      base = math.max(v.topline - (entry.clip or 0), 1)
      entry.base = base
      -- like base: the displayed leftcol minus the horizontal clip we last
      -- applied is the widget's OWN horizontal scroll
      entry.leftcol = math.max((v.leftcol or 0) - (entry.lclip or 0), 0)
      -- Extraction memo: the mirror + transcription depend only on the
      -- widget's own view (base, leftcol), its buffer and the box — none of
      -- which a pure root scroll changes. Redo them only when a flush blanked
      -- the canvas (fresh), a highlight event flagged the entry (view_dirty),
      -- or the key moved. With syntax on, extraction dominates the scroll
      -- frame (~3ms per widget) — this skip is what keeps scrolling flat.
      local key = table.concat({
        base,
        entry.leftcol,
        vim.api.nvim_buf_get_changedtick(entry.bufnr),
        c.x,
        c.y,
        c.w,
        c.h,
      }, ":")
      if fresh or entry.view_dirty or entry.extracted ~= key then
        mirror(entry)
        if policy(entry) == "focus" then
          transcribe(entry)
        end
        entry.extracted = key
        entry.view_dirty = nil
      end
    end

    -- Hidden: occluded/zero-sized, or a render="focus" widget that nobody is
    -- editing (entry.revealing is enter()'s "about to focus" escape hatch).
    if
      vis_bot < vis_top
      or vis_right < vis_left
      or c.w <= 0
      or (policy(entry) == "focus" and not focused and not entry.revealing)
    then
      vim.api.nvim_win_set_config(entry.winid, { hide = true })
      return
    end

    vim.api.nvim_win_set_config(entry.winid, {
      relative = "win",
      win = root_winid,
      row = vis_top,
      col = vis_left,
      width = vis_right - vis_left + 1,
      height = vis_bot - vis_top + 1,
      hide = false,
    })
    -- Clipped at the top: scroll the float's own viewport so the slice below
    -- the occlusion edge is what shows — the clip COMPOSES with the widget's
    -- own scroll (base + clipped). The rest of the view (cursor, columns) is
    -- preserved; the cursor is only dragged as far as keeping topline valid
    -- requires. NEVER while the float is focused: a resync in the middle of
    -- typing (on_change → re-render → flush → here) would yank the cursor
    -- between keystrokes.
    if not focused then
      local clipped = vis_top - y0
      local lclip = vis_left - x0
      local height = vis_bot - vis_top + 1
      v.topline = base + clipped
      v.lnum = math.min(math.max(v.lnum, v.topline), v.topline + height - 1)
      -- Left clip composes into the widget's own leftcol the same way — but
      -- only for nowrap floats: with wrap, leftcol is meaningless and a
      -- narrowed window REWRAPS instead (known mirror divergence, accepted).
      if not (vim.wo[entry.winid].wrap) then
        v.leftcol = (entry.leftcol or 0) + lclip
        -- keep the cursor inside the horizontal view: winrestview would
        -- otherwise let nvim re-scroll to reveal it, undoing the clip
        local w = vis_right - vis_left + 1
        local line = vim.api.nvim_buf_get_lines(entry.bufnr, v.lnum - 1, v.lnum, false)[1] or ""
        local cell = width.str(line:sub(1, math.min(v.col, #line)))
        if cell < v.leftcol then
          v.col = width.cell_to_byte(line, v.leftcol)
        elseif cell >= v.leftcol + w then
          v.col = width.cell_to_byte(line, v.leftcol + w - 1)
        end
      end
      vim.api.nvim_win_call(entry.winid, function()
        vim.fn.winrestview(v)
      end)
      entry.clip = clipped
      entry.lclip = lclip
    end
  end

  -- Move the root cursor to buffer cell (row, x) [0-indexed] and focus the
  -- root. No-op when the target is outside the root buffer — an edge motion
  -- with nowhere to go stays put rather than letting the root clamp the
  -- cursor back inside the widget (which would immediately re-enter it).
  local function exit_to(row, x)
    if not vim.api.nvim_win_is_valid(root_winid) then
      return
    end
    if row < 0 or x < 0 or row >= vim.api.nvim_buf_line_count(host.bufnr) then
      return
    end
    local line = vim.api.nvim_buf_get_lines(host.bufnr, row, row + 1, false)[1] or ""
    if x >= width.str(line) then
      return
    end
    vim.api.nvim_set_current_win(root_winid)
    vim.api.nvim_win_set_cursor(root_winid, { row + 1, width.cell_to_byte(line, x) })
  end

  -- Focus `entry`'s float, placing its cursor at root-buffer cell (row, x)
  -- translated into the float's content (clamped to its lines). A
  -- render="focus" float is revealed first (it cannot be entered hidden);
  -- false when there is nothing focusable (fully occluded).
  local function enter(entry, row, x)
    if not vim.api.nvim_win_is_valid(entry.winid) then
      return false
    end
    if policy(entry) == "focus" then
      entry.revealing = true
      reposition(entry)
      entry.revealing = nil
    end
    if vim.api.nvim_win_get_config(entry.winid).hide then
      return false
    end
    local c = entry.node.content
    local lnum = math.min(math.max(row - c.y + 1, 1), vim.api.nvim_buf_line_count(entry.bufnr))
    local line = vim.api.nvim_buf_get_lines(entry.bufnr, lnum - 1, lnum, false)[1] or ""
    vim.api.nvim_set_current_win(entry.winid)
    vim.api.nvim_win_set_cursor(entry.winid, { lnum, width.cell_to_byte(line, math.max(x - c.x, 0)) })
    return true
  end

  -- The float cursor's (pos, display cell) — cells because the root target of
  -- a vertical exit must keep the cursor's visual column, not its byte one.
  local function float_cursor(entry)
    local pos = vim.api.nvim_win_get_cursor(entry.winid)
    local line = vim.api.nvim_buf_get_lines(entry.bufnr, pos[1] - 1, pos[1], false)[1] or ""
    return pos, width.str(line:sub(1, pos[2]))
  end

  -- Is the float cursor at the buffer edge `dir` would cross?
  local function at_edge(entry, dir)
    local pos = vim.api.nvim_win_get_cursor(entry.winid)
    if dir == "k" then
      return pos[1] == 1
    elseif dir == "j" then
      return pos[1] == vim.api.nvim_buf_line_count(entry.bufnr)
    elseif dir == "h" then
      return pos[2] == 0
    end
    return vim.api.nvim_win_call(entry.winid, function()
      return vim.fn.charcol(".") >= vim.fn.strchars(vim.fn.getline("."))
    end)
  end

  -- Step out of the float in direction `dir`, one cell past the CONTENT box:
  -- with a border that is the border cell itself — symmetric with entry, where
  -- the root cursor crosses the border one keypress at a time. Vertical exits
  -- keep the column, horizontal exits keep the row.
  local function exit_dir(entry, dir)
    local pos, cell = float_cursor(entry)
    local c = entry.node.content
    if dir == "k" then
      exit_to(c.y - 1, c.x + cell)
    elseif dir == "j" then
      exit_to(c.y + c.h, c.x + cell)
    elseif dir == "h" then
      exit_to(c.y + (pos[1] - 1), c.x - 1)
    else
      exit_to(c.y + (pos[1] - 1), c.x + c.w)
    end
  end

  -- Buffer-local traversal maps. A raw_buffer's buffer may be shown in other
  -- windows too, so every callback falls back to the native motion unless the
  -- float itself is the current window.
  local function map_motions(entry)
    local function map(modes, lhs, fn)
      vim.keymap.set(modes, lhs, fn, { buffer = entry.bufnr, nowait = true, desc = "fibrous: subwin traversal" })
      for _, mode in ipairs(type(modes) == "table" and modes or { modes }) do
        entry.maps[#entry.maps + 1] = { mode, lhs }
      end
    end
    entry.map = map

    for _, key in ipairs({ "h", "j", "k", "l" }) do
      map("n", key, function()
        if vim.api.nvim_get_current_win() == entry.winid and at_edge(entry, key) then
          exit_dir(entry, key)
        else
          vim.cmd("normal! " .. vim.v.count1 .. key)
        end
      end)
      map("n", "<C-w>" .. key, function()
        if vim.api.nvim_get_current_win() == entry.winid then
          exit_dir(entry, key)
        else
          vim.cmd(vim.v.count1 .. "wincmd " .. key)
        end
      end)
    end
    for _, key in ipairs({ "<C-d>", "<C-u>" }) do
      map("n", key, function()
        if vim.api.nvim_get_current_win() == entry.winid and vim.api.nvim_win_is_valid(root_winid) then
          vim.api.nvim_set_current_win(root_winid)
        end
        vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(key, true, false, true))
      end)
    end
  end

  -- Keep the mirror synced with the sub buffer: any text change (typing,
  -- :normal, API edits to an unowned raw_buffer, LSP edits) schedules a
  -- reposition — which recaptures the widget's view and rewrites the mirror.
  -- Coalesced like wire_input's watcher; skipped while focused (the float
  -- covers the mirror), the WinLeave refresh below settles it on exit.
  local function wire_mirror(entry)
    local pending = false
    local function refresh()
      if pending then
        return
      end
      pending = true
      vim.schedule(function()
        pending = false
        if entry.dead or not vim.api.nvim_win_is_valid(entry.winid) then
          return
        end
        if entry.winid ~= vim.api.nvim_get_current_win() then
          reposition(entry)
        end
      end)
    end
    vim.api.nvim_buf_attach(entry.bufnr, false, {
      on_lines = function()
        if entry.dead then
          return true -- detach
        end
        refresh()
      end,
    })
    -- Highlight-only changes arrive without on_lines: diagnostics and LSP
    -- semantic tokens land as (persistent) extmark updates with their own
    -- events — and without a changedtick bump, so the extraction memo needs
    -- an explicit dirty flag. pcall: LspTokenUpdate needs nvim 0.10+.
    for _, ev in ipairs({ "DiagnosticChanged", "LspTokenUpdate" }) do
      pcall(vim.api.nvim_create_autocmd, ev, {
        group = group,
        buffer = entry.bufnr,
        callback = function()
          entry.view_dirty = true
          refresh()
        end,
      })
    end
  end

  -- text_input change/submit wiring. Handlers come off entry.node.props at
  -- fire time — sync() refreshes entry.node every flush, so this is always
  -- the latest committed component.
  --
  -- Change detection is nvim_buf_attach, not TextChanged/TextChangedI: those
  -- are main-loop events that never fire while a feedkeys batch is being
  -- processed. on_lines runs under textlock, so the handler (which typically
  -- re-renders, writing the host buffer) is deferred to the main loop,
  -- coalesced so a burst of edits reports once, with the final value.
  local function wire_input(entry)
    local pending = false
    vim.api.nvim_buf_attach(entry.bufnr, false, {
      on_lines = function()
        if entry.dead then
          return true -- detach
        end
        if pending then
          return
        end
        pending = true
        vim.schedule(function()
          pending = false
          if entry.dead or not vim.api.nvim_buf_is_valid(entry.bufnr) then
            return
          end
          local props = entry.node.props or {}
          if props.on_change then
            props.on_change(buf_value(entry.bufnr))
          end
        end)
      end,
    })
    entry.map({ "n", "i" }, "<CR>", function()
      local props = entry.node.props or {}
      if props.on_submit then
        props.on_submit(buf_value(entry.bufnr))
      elseif vim.api.nvim_get_mode().mode:find("i") then
        -- No submit handler: a plain newline. "i" puts it BEFORE whatever is
        -- still in the typeahead, "n" (noremap) keeps it from recursing here.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
      end
    end)
  end

  -- Focus styling ("Style rework" S2): the float gaining/losing the cursor
  -- applies the node's `_focus` style override through host state + relayout
  -- (focus changes are rare — always the structural path, no fast path).
  local function set_focus(entry, on)
    local node = entry.node
    if entry.dead or not node.fiber or not (node.style and node.style.focus) then
      return
    end
    host.set_state(node.fiber, "focus", on)
    host.relayout()
  end

  -- WinEnter/WinLeave fire for any window showing the buffer (a raw_buffer's
  -- may be open elsewhere), so both check that OUR float is the one involved.
  local function wire_focus(entry)
    vim.api.nvim_create_autocmd("WinEnter", {
      group = group,
      buffer = entry.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() == entry.winid then
          set_focus(entry, true)
          -- A hidden float CAN be entered (<C-w>w cycling, direct API) and
          -- would be edited invisibly; any focus path must reveal it.
          reposition(entry)
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = entry.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() == entry.winid then
          set_focus(entry, false)
          -- reposition skips focused floats (typing must not be yanked
          -- around), so edits made while focused settle into the mirror now.
          -- Deferred: WinLeave fires while the float is still current.
          vim.schedule(function()
            if not entry.dead then
              reposition(entry)
            end
          end)
        end
      end,
    })
  end

  local function create(node)
    local props = node.props or {}
    local bufnr, owned
    if node.subwin == "raw_buffer" and props.bufnr then
      bufnr, owned = props.bufnr, false
    else
      bufnr, owned = vim.api.nvim_create_buf(false, true), true
      if node.subwin == "text_input" and props.value and props.value ~= "" then
        -- seeded once — the buffer is the source of truth after
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(props.value, "\n", { plain = true }))
      end
    end
    local winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "win",
      win = root_winid,
      row = 0,
      col = 0,
      width = math.max(node.content.w, 1),
      height = math.max(node.content.h, 1),
      style = "minimal",
      zindex = 60, -- above the root float's 50
      hide = true, -- reposition below decides visibility
    })
    -- text_input never wraps (rect math); raw_buffer is the native-wrapping
    -- escape hatch and wraps unless told not to.
    vim.wo[winid].wrap = node.subwin == "raw_buffer" and props.wrap ~= false

    local entry = { bufnr = bufnr, winid = winid, node = node, owned = owned, maps = {} }
    map_motions(entry)
    wire_focus(entry)
    wire_mirror(entry)
    if node.subwin == "text_input" then
      wire_input(entry)
    end
    return entry
  end

  local function destroy(entry)
    entry.dead = true -- detaches the on_lines watcher on its next callback
    -- Never strand the user's focus: a widget can be unmounted out from under
    -- its own cursor (the TODO pattern — a submit handler inserts a sibling
    -- before the input and the positional reconciler recreates it). Closing
    -- the current window would drop focus into an arbitrary previous window
    -- with the MODE intact — insert mode "in the air" over the unmodifiable
    -- root. Leave insert deliberately and step out to where the widget was.
    if vim.api.nvim_win_is_valid(entry.winid) and vim.api.nvim_get_current_win() == entry.winid then
      if vim.api.nvim_get_mode().mode:find("i") then
        vim.cmd("stopinsert")
      end
      local c = entry.node.content
      exit_to(c.y, c.x)
      if vim.api.nvim_get_current_win() == entry.winid and vim.api.nvim_win_is_valid(root_winid) then
        vim.api.nvim_set_current_win(root_winid) -- exit_to found no cell there
      end
    end
    if entry.ns and vim.api.nvim_buf_is_valid(host.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, host.bufnr, entry.ns, 0, -1)
    end
    if vim.api.nvim_win_is_valid(entry.winid) then
      pcall(vim.api.nvim_win_close, entry.winid, true)
    end
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then
      return
    end
    if entry.owned then
      pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
    else
      -- unowned (caller's raw_buffer): leave the buffer alive, take only our
      -- keymaps and autocmds off it
      for _, m in ipairs(entry.maps) do
        pcall(vim.keymap.del, m[1], m[2], { buffer = entry.bufnr })
      end
      pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = entry.bufnr })
    end
  end

  -- Hold the guicursor shim exactly while a render="always" widget is live:
  -- only then can the root cursor glide UNDER a shown float (the obscured-
  -- cursor underscore); render="focus" floats are hidden when unfocused.
  local shim_held = false
  local function update_shim()
    local wants = false
    for _, entry in pairs(floats) do
      if policy(entry) == "always" then
        wants = true
        break
      end
    end
    if wants and not shim_held then
      cursorshim.acquire()
      shim_held = true
    elseif not wants and shim_held then
      cursorshim.release()
      shim_held = false
    end
  end

  -- Reconcile floats against the host's last flush: create for new subwindow
  -- leaves, reposition everything, destroy floats whose leaf is gone.
  -- `fresh` defaults to true (the on_flush path: the canvas was rewritten);
  -- the WinScrolled resync passes false — nothing under the floats changed.
  local function sync(fresh)
    fresh = fresh ~= false
    local seen = {}
    for _, node in ipairs(host.subwins or {}) do
      local inst = node.fiber and node.fiber.instance
      if inst then
        seen[inst] = true
        local entry = floats[inst]
        if not entry then
          entry = create(node)
          floats[inst] = entry
        end
        entry.node = node
        reposition(entry, fresh)
      end
    end
    for inst, entry in pairs(floats) do
      if not seen[inst] then
        destroy(entry)
        floats[inst] = nil
      end
    end
    update_shim()
  end

  -- Live scroll resync. Deliberately synchronous and uncoalesced — WinScrolled
  -- already fires at most once per redraw, and any deferral widens the swim.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    pattern = tostring(root_winid),
    callback = function()
      sync(false) -- pure scroll: the canvas under the floats is intact
    end,
  })

  -- A user :q on a subwindow float kills the whole app, exactly like :q on
  -- the root — a lone widget window closing has no sensible half-open state.
  -- Closing the ROOT float cascades into the mount target's teardown; our own
  -- destroys set entry.dead before closing, so they don't rebound here.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for _, entry in pairs(floats) do
        if entry.winid == closed and not entry.dead then
          -- deferred: windows can't be closed from inside WinClosed
          vim.schedule(function()
            if vim.api.nvim_win_is_valid(root_winid) then
              pcall(vim.api.nvim_win_close, root_winid, true)
            end
          end)
          return
        end
      end
    end,
  })

  -- Explicit focus entry (no traversal capture): focus the float whose RECT
  -- (border box — entering from a border cell clamps into the content)
  -- contains root-buffer cell (row, x). Returns true when a subwindow took
  -- the focus. interact.lua drives this from <CR>, clicks, and insert keys;
  -- keymaps fire autocmds normally, so WinEnter applies _focus with no
  -- `nested` gymnastics.
  local function enter_at(row, x)
    for _, entry in pairs(floats) do
      local r = entry.node.rect or entry.node.content
      if row >= r.y and row < r.y + r.h and x >= r.x and x < r.x + r.w then
        return enter(entry, row, x)
      end
    end
    return false
  end

  return {
    sync = sync,
    enter_at = enter_at,
    teardown = function()
      for _, entry in pairs(floats) do
        destroy(entry) -- before the augroup goes: destroy clears per-buffer autocmds through it
      end
      floats = {}
      update_shim() -- no floats left: releases the guicursor hold if we had it
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  }
end

return M
