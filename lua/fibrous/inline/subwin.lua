-- The subwindow manager (tracker "NEW UI HOST" tasks 4 + 7). Subwindow leaves
-- (text_input, raw_buffer, container) are laid out inline like everything
-- else — their border/background even paint in the root buffer — but their
-- CONTENT box is covered by a real float anchored to the root float, so the
-- user gets a native buffer to type into (text_input: an owned scratch buffer
-- seeded from props.value; raw_buffer: a caller-provided, UNOWNED props.bufnr,
-- or an owned scratch one without it; container: the host's own flush target
-- for the leaf's children — a container entry recursively attaches a nested
-- manager + interaction layer to ITS float, so inputs and deeper containers
-- inside compose with no extra wiring).
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
--        the root — page motions are never trapped — EXCEPT inside a
--        container, a scrolling region in its own right, where they stay
--        native. Exits whose target falls outside the root buffer are no-ops
--        (staying put beats the root clamping the cursor straight back into
--        the widget). Across nesting levels the same rules apply one hop at a
--        time: entering a container's input is two <CR>s, leaving it is two
--        edge exits.
--
-- text_input wiring: buffer edits report through props.on_change(value)
-- (TextChanged/TextChangedI); <CR> — normal or insert mode — calls
-- props.on_submit(value) when given, otherwise insert-mode <CR> falls through
-- to a plain newline. Handlers are read from the latest committed props at
-- fire time.

local width = require("fibrous.inline.width")
local cursorshim = require("fibrous.inline.cursorshim")
local interact = require("fibrous.inline.interact")

local M = {}

---@class SubwinManager
---@field sync fun(damage?: { top: integer, bot: integer }|false)  reconcile floats against host.subwins and reposition them; damage = the flush's spliced rows (false: none, nil: assume all)
---@field enter_at fun(row: integer, x: integer, insert?: boolean): boolean  focus the subwindow at root cell (row, x), in insert mode when `insert` and the policy allows; false if none there
---@field activate_at fun(row: integer, x: integer, via_click?: boolean): boolean  focus the subwindow at (row, x) AND run its interaction once (press a role / hop deeper) — one-keystroke activation across the boundary; false if none there
---@field hover_at fun(row: integer, x: integer)  parent-driven hover: nudge the (unfocused) container at (row, x) to paint hover under the parent's pointer, without moving focus
---@field clear_hover fun()  drop any parent-driven container hover
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

---@class SubwinAttachOpts
---@field target? FlushTarget  the flush target this manager serves; default the host's root. A container entry spawns a nested manager over ITS target, anchored to the container's float — the same wiring, one level down.
---@field mouse? InlineMouseOpts|false  threaded into nested containers' interaction layers
---@field zindex? integer  this level's float zindex; the mounts pass root+1 (see InlineWindowMountOpts for the stacking policy) and each nesting level stacks +1 so children always cover their container. Default 60 for standalone attaches.

-- Attach a manager to one of `host`'s flush targets, whose buffer is shown in
-- `root_winid` (the mount's root float, or — one level down — a container's
-- float). The mount target calls this once for the root, wires
-- `host.on_flush` to `sync`, and calls `teardown` on unmount; container
-- entries recurse from create().
---@param host InlineHost
---@param root_winid integer
---@param opts? SubwinAttachOpts
---@return SubwinManager
function M.attach(host, root_winid, opts)
	opts = opts or {}
	local target = opts.target or host.root_target
	local zindex = opts.zindex or 60
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
		if entry.node.subwin == "container" then
			-- the float IS the content — a mirror can't stand in for it (it
			-- couldn't carry the container's own nested floats)
			return "always"
		end
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
	-- render="focus" widget is unfocused. A flush blanks the box only when its
	-- damage reaches it (host splices, it no longer repaints wholesale);
	-- sync() re-mirrors exactly then.
	-- Re-derive the canvas highlight marks for rows [y0, y1] from the host's
	-- retained ground truth. mirror()/restore_box() rewrite row content via
	-- set_text, and a replacement covering a mark's exact extent INVERTS it
	-- through gravity (the start has right gravity, the end doesn't): the
	-- start lands at the edit's end, the end at its start, and the highlight
	-- silently disappears until the next splice repaints that row. Marks are
	-- cheap; re-adding the touched rows is exact.
	local function repaint_row_marks(y0, y1)
		local buf, rows, lines = target.bufnr, target.prev_hl_rows, target.prev_lines
		if not rows or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		y0 = math.max(y0, 0)
		y1 = math.min(y1, vim.api.nvim_buf_line_count(buf) - 1)
		if y1 < y0 then
			return
		end
		vim.api.nvim_buf_clear_namespace(buf, host.ns, y0, y1 + 1)
		for y = y0, y1 do
			local spans = rows[y + 1]
			if spans and #spans > 0 then
				-- Ground-truth span positions are CANVAS bytes, but mirror writes
				-- change the row's byte layout (multibyte widget cells over
				-- single-byte canvas cells and vice versa) — placing them raw
				-- shifts every mark beside the box off its text. Translate
				-- through display cells whenever the line diverged.
				local canvas_line = lines and lines[y + 1]
				local cur_line = vim.api.nvim_buf_get_lines(buf, y, y + 1, false)[1] or ""
				local diverged = canvas_line ~= nil and cur_line ~= canvas_line
				for _, s in ipairs(spans) do
					local start_col, end_col = s.start_col, s.end_col
					if diverged then
						start_col = width.cell_to_byte(cur_line, width.str(canvas_line:sub(1, start_col)))
						end_col = width.cell_to_byte(cur_line, width.str(canvas_line:sub(1, end_col)))
					end
					-- strict=false: a mirrored row's byte length may still run short
					-- of the translated extent (cell-equal, byte-different) — clamp.
					vim.api.nvim_buf_set_extmark(buf, host.ns, s.row, start_col, {
						end_col = end_col,
						hl_group = s.hl,
						strict = false,
					})
				end
			end
		end
	end

	local function mirror(entry)
		if not vim.api.nvim_buf_is_valid(target.bufnr) or not vim.api.nvim_buf_is_valid(entry.bufnr) then
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

		local last = vim.api.nvim_buf_line_count(target.bufnr) - 1
		vim.bo[target.bufnr].modifiable = true
		for i = 0, c.h - 1 do
			local y = c.y + i
			if y >= 0 and y <= last then
				local root_line = vim.api.nvim_buf_get_lines(target.bufnr, y, y + 1, false)[1] or ""
				local b0 = width.cell_to_byte(root_line, c.x)
				local b1 = width.cell_to_byte(root_line, c.x + c.w)
				if b1 <= #root_line then
					vim.api.nvim_buf_set_text(target.bufnr, y, b0, y, b1, { rows[i + 1] })
				end
			end
		end
		vim.bo[target.bufnr].modifiable = false
		repaint_row_marks(c.y, c.y + c.h - 1)
		-- what we painted over, so the box can be restored when it moves or dies
		entry.mirrored = { x = c.x, y = c.y, w = c.w, h = c.h }
	end

	-- Undo a mirror: write the host's retained canvas (the pre-mirror ground
	-- truth) back over box `b`. Damage-tracked flushes leave unchanged rows
	-- alone, so a mirror outlives its widget unless somebody cleans it up —
	-- this runs when a widget is destroyed or its box changes.
	local function restore_box(b)
		local canvas = target.canvas_lines
		if not canvas or not vim.api.nvim_buf_is_valid(target.bufnr) or b.w <= 0 then
			return
		end
		local last = vim.api.nvim_buf_line_count(target.bufnr) - 1
		vim.bo[target.bufnr].modifiable = true
		for y = math.max(b.y, 0), math.min(b.y + b.h - 1, last) do
			local cline = canvas[y + 1]
			if cline then
				local root_line = vim.api.nvim_buf_get_lines(target.bufnr, y, y + 1, false)[1] or ""
				local b0 = width.cell_to_byte(root_line, b.x)
				local b1 = width.cell_to_byte(root_line, b.x + b.w)
				if b1 <= #root_line then
					local s0 = width.cell_to_byte(cline, b.x)
					local s1 = width.cell_to_byte(cline, b.x + b.w)
					vim.api.nvim_buf_set_text(target.bufnr, y, b0, y, b1, { cline:sub(s0 + 1, s1) })
				end
			end
		end
		vim.bo[target.bufnr].modifiable = false
		repaint_row_marks(b.y, b.y + b.h - 1)
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
		local last = vim.api.nvim_buf_line_count(target.bufnr) - 1
		-- Clear the WHOLE namespace, not just the box rows: every canvas flush
		-- is a full set_lines that RELOCATES existing marks out of the box,
		-- where a ranged clear would miss them forever — they accumulate by the
		-- hundreds per flush and frame times grow linearly.
		vim.api.nvim_buf_clear_namespace(target.bufnr, entry.ns, 0, -1)
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
			local root_line = vim.api.nvim_buf_get_lines(target.bufnr, y, y + 1, false)[1] or ""
			vim.api.nvim_buf_set_extmark(target.bufnr, entry.ns, y, width.cell_to_byte(root_line, c.x + s), {
				end_col = width.cell_to_byte(root_line, c.x + e),
				hl_group = hl,
				priority = prio,
			})
		end

		for i = 1, c.h do
			local m = map[i]
			if m then
				local sline = vim.api.nvim_buf_get_lines(entry.bufnr, m.lnum - 1, m.lnum, false)[1] or ""

				for _, mk in
					ipairs(
						vim.api.nvim_buf_get_extmarks(
							entry.bufnr,
							-1,
							{ m.lnum - 1, 0 },
							{ m.lnum - 1, -1 },
							{ details = true, overlap = true }
						)
					)
				do
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
	-- the root's current scroll position. `forced` means a flush just spliced
	-- rows through the content box: the mirror there is canvas-blank again and
	-- must be re-extracted no matter what the memo says.
	local function reposition(entry, forced)
		if not (vim.api.nvim_win_is_valid(root_winid) and vim.api.nvim_win_is_valid(entry.winid)) then
			return
		end
		-- A nested manager's "root" is a container float, which can itself be
		-- hidden (fully occluded in ITS parent): everything under it hides too.
		if vim.api.nvim_win_get_config(root_winid).hide then
			vim.api.nvim_win_set_config(entry.winid, { hide = true })
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
		if focused and forced then
			-- The splice blanked our box while the float covered it. We must not
			-- touch the view mid-typing, but the memo now lies: invalidate it so
			-- leaving the widget re-extracts (else the mirror shows blank until
			-- some later flush happens to hit the box again).
			entry.extracted = nil
		end
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
			-- which a pure root scroll or an elsewhere-damage flush changes. Redo
			-- them only when a splice blanked the box (forced), a highlight event
			-- flagged the entry (view_dirty), or the key moved. With syntax on,
			-- extraction dominates the frame (~3ms per widget) — this skip is what
			-- keeps scrolling and unrelated updates flat.
			local key = table.concat({
				base,
				entry.leftcol,
				vim.api.nvim_buf_get_changedtick(entry.bufnr),
				c.x,
				c.y,
				c.w,
				c.h,
			}, ":")
			if forced or entry.view_dirty or entry.extracted ~= key then
				-- A moved/resized box leaves the old one's mirror stranded (no full
				-- repaint sweeps it away anymore): restore the canvas there first.
				local mb = entry.mirrored
				if mb and (mb.x ~= c.x or mb.y ~= c.y or mb.w ~= c.w or mb.h ~= c.h) then
					restore_box(mb)
				end
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
		local clipped = vis_top - y0
		local lclip = vis_left - x0
		if not focused then
			local height = vis_bot - vis_top + 1
			v.topline = base + clipped
			v.lnum = math.min(math.max(v.lnum, v.topline), v.topline + height - 1)
			-- Left clip composes into the widget's own leftcol the same way — but
			-- only for nowrap floats: with wrap, leftcol is meaningless and a
			-- narrowed window REWRAPS instead (known mirror divergence, accepted).
			if not vim.wo[entry.winid].wrap then
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
		end
		-- Record the clip for the geometry just applied EVEN WHILE FOCUSED:
		-- the view is deliberately left alone then, but the resize above makes
		-- nvim re-anchor topline around the cursor — so the own-scroll
		-- reconstruction at the next capture (base = topline - clip) must
		-- subtract the clip this geometry has, not the last unfocused visit's.
		-- A stale clip is a phantom scroll: the mirror renders the wrong slice
		-- and the next entry teleports.
		entry.clip = clipped
		entry.lclip = lclip
	end

	-- Move the root cursor to buffer cell (row, x) [0-indexed] and focus the
	-- root. No-op when the target is outside the root buffer — an edge motion
	-- with nowhere to go stays put rather than letting the root clamp the
	-- cursor back inside the widget (which would immediately re-enter it).
	local function exit_to(row, x)
		if not vim.api.nvim_win_is_valid(root_winid) then
			return
		end
		if row < 0 or x < 0 or row >= vim.api.nvim_buf_line_count(target.bufnr) then
			return
		end
		local line = vim.api.nvim_buf_get_lines(target.bufnr, row, row + 1, false)[1] or ""
		if x >= width.str(line) then
			return
		end
		vim.api.nvim_set_current_win(root_winid)
		vim.api.nvim_win_set_cursor(root_winid, { row + 1, width.cell_to_byte(line, x) })
	end

	-- Click-to-insert policy: clicking a text field means "edit it" — a
	-- pointer user may have no keyboard at all (on mobile the OSK only
	-- appears once the guest is in an insert-ish mode, so normal mode is a
	-- trap you cannot type your way out of). text_input defaults on;
	-- raw_buffer (arbitrary content, often read-only) defaults off;
	-- props.insert_on_click overrides either way. Keyboard entry (<CR>, the
	-- i/a/o replays) is never affected.
	local function click_insert(entry)
		local props = entry.node.props or {}
		if props.insert_on_click ~= nil then
			return props.insert_on_click
		end
		return entry.node.subwin == "text_input"
	end

	-- Translate a root-buffer cell (row, x) into the (lnum, display cell) of the
	-- float buffer it overlays. Land where the user is LOOKING: the mirror's row
	-- map records, per box row, exactly which buffer line and starting cell it
	-- shows — the one true translation once the widget has scroll state of its
	-- own (base, leftcol) or wraps (one buffer line across several rows, where
	-- base + row-offset arithmetic teleports by one line per wrapped row). The
	-- arithmetic fallback covers blank padding rows and a not-yet-mirrored
	-- widget. Always a VISIBLE line, so a set_cursor to it never scrolls the
	-- float. Shared by enter() (focus landing) and hover_at (parent-driven
	-- hover).
	---@param entry table  a subwindow float entry
	---@param row integer  root-buffer row (0-indexed)
	---@param x integer  root-buffer display cell (0-indexed)
	---@return integer lnum  1-indexed line in the float's buffer
	---@return integer cell  display cell within that line
	local function translate(entry, row, x)
		local c = entry.node.content
		local count = vim.api.nvim_buf_line_count(entry.bufnr)
		local m = entry.mirror_map and entry.mirror_map[row - c.y + 1]
		if m and m.lnum <= count then
			return m.lnum, m.cell0 + math.max(x - c.x, 0)
		end
		return math.min(math.max((entry.base or 1) + (row - c.y), 1), count), (entry.leftcol or 0) + math.max(x - c.x, 0)
	end

	-- Focus `entry`'s float, placing its cursor at root-buffer cell (row, x)
	-- translated into the float's content (clamped to its lines). `insert`
	-- (the click path) also starts insert mode when the policy allows. A
	-- render="focus" float is revealed first (it cannot be entered hidden);
	-- false when there is nothing focusable (fully occluded).
	local function enter(entry, row, x, insert)
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
		local lnum, cell = translate(entry, row, x)
		local line = vim.api.nvim_buf_get_lines(entry.bufnr, lnum - 1, lnum, false)[1] or ""
		vim.api.nvim_set_current_win(entry.winid)
		vim.api.nvim_win_set_cursor(entry.winid, { lnum, width.cell_to_byte(line, cell) })
		if insert and click_insert(entry) then
			-- takes effect when the calling mapping ends; a click past the end
			-- of the line appends (GUI caret lands after the text)
			vim.cmd(cell >= width.str(line) and "startinsert!" or "startinsert")
		end
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
		-- Buffer position → the box row/cell that SHOWS it, via the mirror's
		-- row map (enter()'s translation inverted — under wrap the mapping is
		-- non-linear, and the widget's own scroll offsets it). Arithmetic
		-- fallback for a widget that never mirrored; clamped into the box so
		-- the exit target always sits beside the box.
		local drow, dcell
		for i, mm in ipairs(entry.mirror_map or {}) do
			if mm.lnum == pos[1] and cell >= mm.cell0 and cell < mm.cell0 + c.w then
				drow, dcell = i - 1, cell - mm.cell0
				break
			end
		end
		drow = drow or (pos[1] - (entry.base or 1))
		dcell = dcell or math.max(cell - (entry.leftcol or 0), 0)
		local srow = math.min(math.max(c.y + drow, c.y), c.y + c.h - 1)
		local scol = math.min(math.max(c.x + dcell, c.x), c.x + c.w - 1)
		if dir == "k" then
			exit_to(c.y - 1, scol)
		elseif dir == "j" then
			exit_to(c.y + c.h, scol)
		elseif dir == "h" then
			exit_to(srow, c.x - 1)
		else
			exit_to(srow, c.x + c.w)
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
		-- Page motions hand off to the root so they are never trapped in a
		-- one-line input — EXCEPT in a container, which is a scrolling region
		-- in its own right: there they stay native (the float scrolls).
		if entry.node.subwin ~= "container" then
			for _, key in ipairs({ "<C-d>", "<C-u>" }) do
				map("n", key, function()
					if vim.api.nvim_get_current_win() == entry.winid and vim.api.nvim_win_is_valid(root_winid) then
						vim.api.nvim_set_current_win(root_winid)
					end
					vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(key, true, false, true))
				end)
			end
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
				-- clear_on_submit: the buffer is the source of truth after the seed,
				-- so a chat-style "submit empties the input" must be done HERE — the
				-- app has no handle on the buffer to clear it from on_submit.
				if props.clear_on_submit and vim.api.nvim_buf_is_valid(entry.bufnr) then
					vim.api.nvim_buf_set_lines(entry.bufnr, 0, -1, false, { "" })
				end
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

	-- The entry currently holding the focus state, so a desync can be healed:
	-- focus can leave a float WITHOUT WinLeave firing (nvim's own startup
	-- re-enters the first window between `-u init` sourcing and VimEnter;
	-- plugins switch windows under `:noautocmd`), which would strand the
	-- _focus style ON. The manager-level WinEnter below reconciles on the
	-- next genuine window entry anywhere.
	local focused_entry
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			local e = focused_entry
			if e and vim.api.nvim_get_current_win() ~= e.winid then
				focused_entry = nil
				set_focus(e, false)
			end
		end,
	})

	-- WinEnter/WinLeave fire for any window showing the buffer (a raw_buffer's
	-- may be open elsewhere), so both check that OUR float is the one involved.
	local function wire_focus(entry)
		vim.api.nvim_create_autocmd("WinEnter", {
			group = group,
			buffer = entry.bufnr,
			callback = function()
				if vim.api.nvim_get_current_win() == entry.winid then
					focused_entry = entry
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
					focused_entry = nil
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
		if node.subwin == "container" then
			-- the container's buffer is the host's (a flush target, already
			-- painted by the time sync runs); destroy retires it via drop_target
			bufnr, owned = host.targets[node.fiber].bufnr, false
		elseif node.subwin == "raw_buffer" and props.bufnr then
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
			zindex = zindex, -- one above this level's root (the mount's, or a container's)
			hide = true, -- reposition below decides visibility
		})
		-- text_input never wraps (rect math); raw_buffer is the native-wrapping
		-- escape hatch and wraps unless told not to.
		vim.wo[winid].wrap = node.subwin == "raw_buffer" and props.wrap ~= false

		local entry = { bufnr = bufnr, winid = winid, node = node, owned = owned, maps = {} }
		map_motions(entry)
		-- The native half of click-to-insert: a click on a VISIBLE float never
		-- reaches the root's <LeftRelease> map — core focuses the float on the
		-- press and delivers the release to its buffer. Normal-mode only, so a
		-- drag-selection's release (visual mode by then) never fires it.
		entry.map("n", "<LeftRelease>", function()
			if vim.api.nvim_get_current_win() == entry.winid and click_insert(entry) then
				-- coladd > 0 = the click landed past the end of the line: append
				vim.cmd(vim.fn.getmousepos().coladd > 0 and "startinsert!" or "startinsert")
			end
		end)
		wire_focus(entry)
		wire_mirror(entry)
		if node.subwin == "text_input" then
			wire_input(entry)
			-- Creation-time escape hatch: hand the app the input's buffer so it
			-- can wire buffer-local options/maps (completefunc, steer keymaps…).
			-- Once — the buffer persists across re-renders; only a remount refires.
			if props.on_create then
				props.on_create(bufnr)
			end
		elseif node.subwin == "container" then
			-- The container's own subwindows (inputs, deeper containers) get a
			-- manager + interaction layer of their own, anchored to THIS float —
			-- exactly the wiring the mount does for the root, one level down.
			-- sync() descends into them with the child target's damage.
			entry.child_target = host.targets[node.fiber]
			entry.child_manager = M.attach(host, winid, {
				target = entry.child_target,
				mouse = opts.mouse,
				zindex = zindex + 1,
			})
			entry.child_interact = interact.attach(host, winid, opts.mouse, entry.child_manager, entry.child_target)
			-- Creation-time escape hatch, like text_input's — the container also
			-- hands over its float, the app's handle for window work
			-- (buffer-local keymaps, follow-scroll, focusing).
			if props.on_create then
				props.on_create(bufnr, winid)
			end
		end
		return entry
	end

	local function destroy(entry)
		entry.dead = true -- detaches the on_lines watcher on its next callback
		-- Innermost first: a container's own widgets die before it does. Their
		-- destroys run their own focus-strand exits, which land in THIS entry's
		-- window — so the strand guard below still sees the focus and walks it
		-- the rest of the way out.
		if entry.child_manager then
			entry.child_interact.teardown()
			entry.child_manager.teardown()
		end
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
		-- The buffer no longer gets a wholesale repaint: take our mirror text off
		-- the canvas ourselves, or it lingers wherever the next flush's damage
		-- doesn't reach.
		if entry.mirrored then
			restore_box(entry.mirrored)
		end
		if entry.ns and vim.api.nvim_buf_is_valid(target.bufnr) then
			pcall(vim.api.nvim_buf_clear_namespace, target.bufnr, entry.ns, 0, -1)
		end
		if vim.api.nvim_win_is_valid(entry.winid) then
			pcall(vim.api.nvim_win_close, entry.winid, true)
		end
		if entry.node.subwin == "container" then
			-- the buffer is the host's flush target: retire both together
			host.drop_target(entry.node.fiber)
			return
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

	-- Does this flush's damage reach `node`'s content box?
	--   nil    = unknown (a caller without damage info): assume everything
	--   false  = nothing changed under the floats (pure scroll, no-op flush)
	--   table  = the spliced row range; bot < top is a pure deletion (no new
	--            rows written — shifted widgets re-extract via their memo key)
	local function hit(damage, node)
		if damage == nil then
			return true
		end
		if damage == false or damage.bot < damage.top then
			return false
		end
		local c = node.content
		return c.y <= damage.bot and c.y + c.h - 1 >= damage.top
	end

	-- Reconcile floats against the host's last flush: destroy floats whose leaf
	-- is gone, create for new subwindow leaves, reposition everything. Destroys
	-- run FIRST — a destroyed widget restores the canvas under its old box,
	-- which must not land on top of a surviving widget's freshly written
	-- mirror. `damage` is the flush's spliced row range (see `hit`).
	local function sync(damage)
		local seen = {}
		for _, node in ipairs(target.subwins or {}) do
			local inst = node.fiber and node.fiber.instance
			if inst then
				seen[inst] = true
			end
		end
		for inst, entry in pairs(floats) do
			if not seen[inst] then
				destroy(entry)
				floats[inst] = nil
			end
		end
		for _, node in ipairs(target.subwins or {}) do
			local inst = node.fiber and node.fiber.instance
			if inst then
				local entry = floats[inst]
				if not entry then
					entry = create(node)
					floats[inst] = entry
				end
				entry.node = node
				reposition(entry, hit(damage, node))
				if entry.child_manager then
					-- descend with the child target's OWN damage (accumulated on
					-- the host — this level's splice says nothing about it); a
					-- pure scroll here still repositions the child floats, whose
					-- visible slices moved with the container's
					entry.child_manager.sync(host.take_damage(node.fiber))
					entry.child_interact.update()
				end
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
	local function enter_at(row, x, insert)
		for _, entry in pairs(floats) do
			local r = entry.node.rect or entry.node.content
			if row >= r.y and row < r.y + r.h and x >= r.x and x < r.x + r.w then
				return enter(entry, row, x, insert)
			end
		end
		return false
	end

	-- Like enter_at, but also RUNS the entered subwindow's own interaction once
	-- it has focus — so <CR>/click over a button inside a container presses it
	-- in a single keystroke instead of "one to enter, one to press". Only a
	-- container has an interaction layer to delegate to; a text_input/raw_buffer
	-- is just focused (its enter IS the whole action). Recurses through nesting:
	-- the container's activate calls its OWN activate_at, so a button any number
	-- of containers deep is one <CR>.
	local function activate_at(row, x, via_click)
		for _, entry in pairs(floats) do
			local r = entry.node.rect or entry.node.content
			if row >= r.y and row < r.y + r.h and x >= r.x and x < r.x + r.w then
				local ok = enter(entry, row, x, via_click)
				if ok and entry.child_interact then
					entry.child_interact.activate(true, via_click)
				end
				return ok
			end
		end
		return false
	end

	-- The container currently showing parent-driven hover (its cursor nudged to
	-- follow the parent's pointer), so it can be cleared when the pointer leaves.
	---@type table|nil
	local hovered_hover_entry

	-- Drop any parent-driven hover: tell the tracked container's own interaction
	-- layer to clear (which recurses into its nested containers).
	local function clear_hover()
		if hovered_hover_entry and not hovered_hover_entry.dead and hovered_hover_entry.child_interact then
			hovered_hover_entry.child_interact.clear_hover()
		end
		hovered_hover_entry = nil
	end

	-- Parent-driven hover across the boundary: the parent's cursor is over the
	-- container at (row, x) but focus stays on the parent, so the container's own
	-- (unfocused) cursor never tracks it. We nudge that cursor to the translated,
	-- always-visible cell (no scroll — see translate) WITHOUT focusing the float,
	-- then run the container's own interaction so it paints hover on the float
	-- the user actually sees. Only containers carry an interaction layer; a bare
	-- text_input/raw_buffer has no roles to hover. Recurses: the delegated
	-- update() propagates into deeper containers.
	---@param row integer  parent-buffer row (0-indexed)
	---@param x integer  parent-buffer display cell (0-indexed)
	local function hover_at(row, x)
		---@type table|nil
		local target
		for _, entry in pairs(floats) do
			if entry.child_interact and vim.api.nvim_win_is_valid(entry.winid) then
				local r = entry.node.rect or entry.node.content
				if row >= r.y and row < r.y + r.h and x >= r.x and x < r.x + r.w then
					target = entry
					break
				end
			end
		end
		if hovered_hover_entry and hovered_hover_entry ~= target then
			clear_hover()
		end
		if target then
			local lnum, cell = translate(target, row, x)
			local line = vim.api.nvim_buf_get_lines(target.bufnr, lnum - 1, lnum, false)[1] or ""
			pcall(vim.api.nvim_win_set_cursor, target.winid, { lnum, width.cell_to_byte(line, cell) })
			target.child_interact.update(true) -- propagate: drive deeper containers too
			hovered_hover_entry = target
		end
	end

	return {
		sync = sync,
		enter_at = enter_at,
		activate_at = activate_at,
		hover_at = hover_at,
		clear_hover = clear_hover,
		teardown = function()
			hovered_hover_entry = nil
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
