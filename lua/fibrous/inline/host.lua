-- The inline HostConfig (tracker "NEW UI HOST" task 3): the concrete bridge
-- the reconciler drives for the inline UI host. Rather than giving every
-- leaf its own window, the WHOLE committed fiber tree becomes one layout
-- tree (layout.compute), one painted canvas (render.paint), and one flush into
-- a single host-owned scratch buffer — full lines plus extmark highlight
-- spans. A mount target (inline/mount.lua) shows that buffer in the root float
-- and owns all window concerns; this module never touches windows.
--
-- Multi-container ("subwindow" rework): `container` boundaries split that
-- one buffer into a TREE of flush targets while the fiber tree stays single.
-- A container is a subwindow leaf in its parent's layout tree (border/
-- background inline, a float covers the content box), and its children build
-- into a separate layout tree flushed — with the identical incremental
-- pipeline, all per-target state below — into the container's own buffer.
-- Targets flush parent-first, so a child's constraint comes from its freshly
-- laid-out boundary rect; subwin.lua shows each target in a float anchored to
-- its parent's window, recursively.
--
-- Sizing is injected via `opts.get_size`, read at every flush so the mount
-- target's window is the single source of truth. height = nil is scroll mode
-- (canvas height = content height; the window is a viewport over the buffer),
-- a number is app mode (fixed canvas). `relayout()` re-runs layout + paint at
-- the current size from the last committed tree without re-rendering any
-- component — the mount target's resize-sync entry point.
--
-- Perf posture (tracker Decisions, revised): a commit is still a pure
-- function of (fiber tree, size) — but every stage is memoized on what
-- actually changed:
--   * build     untouched fiber subtrees (dirtiness ticks, fiber.lua) keep
--               their node OBJECTS (fiber._node);
--   * layout    reused nodes skip measure under the same constraint and skip
--               positioning under the same box (layout.compute `_memo`);
--   * paint     a persistent canvas repaints only changed subtrees
--               (render.update) while the size holds;
--   * write     the buffer gets the minimal splice against the previous
--               frame's lines/spans (marks cleared BEFORE the write, while
--               they are still where they were put), and a fully clean frame
--               at the same size skips the flush outright.
-- Every path falls back to the full rebuild/paint when its precondition
-- breaks, so the result is always byte-identical to a fresh paint (the
-- memo_spec fresh-mount oracles pin that). `on_flush` receives the damage —
-- nil when the canvas didn't change, else { top, bot } 0-based inclusive rows
-- of the new frame (bot < top: pure deletion at `top`) — so the subwin
-- manager can leave untouched widgets' mirrors alone.

local Fiber = require("fibrous.reactive.fiber")
local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local style = require("fibrous.inline.style")
local theme = require("fibrous.inline.theme")
local visualsel = require("fibrous.inline.visualsel")
local width = require("fibrous.inline.width")

local M = {}

local CONTAINERS = { col = true, row = true }
-- text_input is a subwindow leaf: laid out (and its border/background painted)
-- inline like any node, but its content box is covered by a real float that
-- subwin.lua manages — the node carries `subwin` so the manager can find it.
-- container is the multi-buffer boundary: a subwindow leaf here, whose
-- CHILDREN build into a separate tree flushed to the container's own buffer.
local LEAVES = { text = true, text_input = true, raw_buffer = true, container = true }

-- One namespace for all inline hosts; each host only ever clears its own buffer.
local ns = vim.api.nvim_create_namespace("fibrous_inline")

-- Attach the node's normalized style plus its state-applied resolution
-- ("Style rework"): normalize once per commit, seeding the theme defaults the
-- node's `theme` prop keys into (components tag themselves; `theme = false`
-- opts out); when the fiber has active interaction states, apply them so
-- layout/paint see the overridden style. With no states the base IS the
-- resolution — shared, no copy.
---@param node table
---@param states table<Fiber, table>
local function attach_style(node, states)
	local props = node.props or {}
	local defaults = nil
	if props.theme then
		defaults = theme.styles[props.theme]
		if not defaults then
			error("fibrous: unknown theme key '" .. tostring(props.theme) .. "'")
		end
	elseif props.theme == nil then
		-- No explicit key: host primitives default to their own tag (text_input,
		-- text, col, row, raw_buffer), so theme.styles can target a whole node
		-- kind. A missing entry is simply unthemed; `theme = false` opts out.
		defaults = theme.styles[node.subwin or node.kind]
	end
	local norm = style.normalize(props, defaults)
	node.style = norm
	local active = states[node.fiber]
	node.style_resolved = active and style.apply(norm, active) or norm.base
	return node
end

-- The live line count an auto-sized raw_buffer measures from.
---@param props table
---@return integer
local function rb_count(props)
	return props.bufnr and vim.api.nvim_buf_is_valid(props.bufnr) and vim.api.nvim_buf_line_count(props.bufnr) or 1
end

-- Nodes accumulate ~20 hash fields over build + measure + layout + paint;
-- pre-sizing the hash part keeps LuaJIT from rehashing the table three times
-- on the way (a measurable share of full-rebuild flushes).
local has_tnew, table_new = pcall(require, "table.new")
if not has_tnew then
	table_new = nil
end
---@param kind string
---@param props table
---@param fiber Fiber
---@return table
local function new_node(kind, props, fiber)
	local node = table_new and table_new(0, 16) or {}
	node.kind = kind
	node.props = props
	node.fiber = fiber
	-- Stable identity for cursor anchoring (interact.lua reanchor): carried from
	-- the fiber's spec `key`. Only nodes whose fiber was given a key get one.
	node.key = fiber.key
	return node
end

---@class BuildCtx
---@field states table<Fiber, table>  active interaction states, keyed by fiber
---@field last_tick integer           tick of the previous flush (reuse cutoff)

-- Build the layout-tree node for a fiber, descending through function
-- components to the host nodes they render. Each node keeps a `fiber` backref
-- (the hit-map ground truth for cursor interaction, task 6), and each host
-- fiber keeps its node (`fiber._node`) — the memo.
--
-- Subtree memoization: a fiber whose subtree hasn't changed since the last
-- flush (tree_tick — renders and set_state flips both bump it) gets its
-- previous node OBJECT back, styles, sizes and rects intact. `_memo` marks it
-- for layout.compute's skips. Anything rebuilt is a fresh table (no _memo),
-- and every ancestor of a change is rebuilt too (Fiber.touch guarantees the
-- path is dirty), so fresh nodes always get measured and positioned.
---@param fiber Fiber
---@param ctx BuildCtx
---@return table|nil node
local function build_node(fiber, ctx)
	if type(fiber.type) == "function" then
		local child = fiber.child_fibers and fiber.child_fibers[1]
		local node = child and build_node(child, ctx) or nil
		-- A keyed function component (an entry wrapper) has no node of its own —
		-- stamp its key onto the host node it renders so anchoring can find it.
		-- The outermost keyed wrapper wins (this runs as recursion unwinds).
		if node and fiber.key ~= nil then
			node.key = fiber.key
		end
		return node
	end

	local tag = fiber.type.__host
	local props = fiber.props or {}
	local prev = fiber._node
	if
		prev
		and (fiber.tree_tick or 0) <= ctx.last_tick
		-- an auto-sized raw_buffer measures LIVE buffer state, which can
		-- change without any fiber rendering — recheck its line count
		and not (prev.subwin == "raw_buffer" and not props.height and rb_count(props) ~= prev._rb_count)
	then
		prev._memo = true
		if prev.inner then
			-- honest: the memo hit means nothing under this fiber changed, so
			-- the inner tree's layout/paint can skip wholesale too
			prev.inner._memo = true
		end
		return prev
	end

	local node = new_node(tag, props, fiber)
	if CONTAINERS[tag] then
		local children = {}
		for _, cf in ipairs(fiber.child_fibers or {}) do
			local child = build_node(cf, ctx)
			if child then
				children[#children + 1] = child
			end
		end
		node.children = children
	elseif tag == "container" then
		-- The boundary is a subwindow leaf in THIS tree (border/background
		-- paint inline, a float covers the content box — like text_input), but
		-- its children build into a SEPARATE tree, hung off the node: the host
		-- lays it out and flushes it into the container's own buffer (a flush
		-- target) once the boundary's content box is known. One fiber tree
		-- throughout — dirtiness ticks, memoization and set_state cross the
		-- boundary like any other edge.
		node.kind = "text"
		node.subwin = "container"
		node.text = ""
		local children = {}
		for _, cf in ipairs(fiber.child_fibers or {}) do
			local child = build_node(cf, ctx)
			if child then
				children[#children + 1] = child
			end
		end
		local inner = new_node("col", { gap = props.gap, align = props.align, justify = props.justify }, fiber)
		inner.children = children
		attach_style(inner, ctx.states)
		node.inner = inner
	elseif tag == "text_input" or tag == "raw_buffer" then
		-- Subwindow leaves measure as text (one content row unless props size
		-- them); the float shows the real content, so nothing is painted in the
		-- content box at layout time — but border/background still render inline
		-- in the root buffer, and subwin.lua mirrors the buffer's visible slice
		-- into those cells after every flush. A raw_buffer without an explicit
		-- height sizes itself to its buffer's line count: N-1 newlines measure
		-- as N empty rows. props.render = "focus" (default) | "always" picks the
		-- float policy: hidden until focused with the mirror (plus transcribed
		-- highlights) standing in, or always shown.
		node.kind = "text"
		node.subwin = tag
		node.text = ""
		if tag == "raw_buffer" and not props.height then
			local count = rb_count(props)
			node.text = ("\n"):rep(count - 1)
			node._rb_count = count
		end
	else
		node.kind = "text"
		node.text = props.text or ""
		-- `fill`: content generated from the node's FINAL width at layout time
		-- (layout.lua) — a width-aware text node that spans its stretched/grown
		-- box and re-fills on resize with no re-render.
		if type(props.fill) == "function" then
			node.fill = props.fill
		end
	end
	attach_style(node, ctx.states)
	-- Tier B (incremental paint) bookkeeping, stored only off the fast path:
	-- `_keep` marks a node rebuilt ONLY because a descendant changed (its own
	-- visual is intact — the paint can descend instead of repainting it), and
	-- `_old_rect` remembers where its previous incarnation sat. A rebuilt
	-- CONTAINER additionally carries its previous incarnation (`_prev`): the
	-- fiber DID render — a list component committing a fresh children array —
	-- but if the paint finds the old chrome and child count intact it can
	-- still descend instead of repainting every entry (render.update's
	-- chrome_equal). The painter consumes the field on every path, so old
	-- nodes never chain alive across frames.
	if prev then
		if (fiber.self_tick or 0) <= ctx.last_tick then
			node._keep = true
		end
		node._old_rect = prev.rect
		-- `_drop`: the reconciler dropped a child fiber under this node this frame
		-- (a positional replace or a trailing removal). render.update scans for the
		-- removed children's orphaned cells only when it is set — the transcript
		-- append/stream path drops nothing and pays nothing.
		if CONTAINERS[tag] then
			node._prev = prev
			node._drop = fiber._child_dropped or nil
		end
		if node.inner and prev.inner then
			-- the inner root gets the same incremental-paint bookkeeping, so a
			-- rebuilt boundary (one changed entry in a long list) descends in
			-- the container's canvas instead of repainting it wholesale
			if (fiber.self_tick or 0) <= ctx.last_tick then
				node.inner._keep = true
			end
			node.inner._old_rect = prev.inner.rect
			node.inner._prev = prev.inner
			node.inner._drop = fiber._child_dropped or nil
		end
	end
	fiber._child_dropped = nil -- consumed into the node(s) built this frame
	fiber._node = node
	return node
end

-- Collect the laid-out subwindow nodes of `tree` (document order).
---@param node table
---@param out table[]
local function collect_subwins(node, out)
	if node.subwin then
		out[#out + 1] = node
	end
	for _, child in ipairs(node.children or {}) do
		collect_subwins(child, out)
	end
end

---@class InlineHostOpts
---@field get_size fun(): { width: integer, height: integer|nil }  read at every flush; nil height = scroll mode
---@field on_flush? fun(damage: { top: integer, bot: integer }|nil)  called after every flush (commit or relayout); damage nil = canvas unchanged

---@class InlineHost : HostConfig
---@field bufnr integer   the host-owned scratch buffer mount targets display
---@field ns integer      extmark namespace of the highlight spans
---@field tree table|nil  the last laid-out ROOT tree (rects are buffer coordinates)
---@field subwins table[] laid-out subwindow nodes of the root's last flush (document order)
---@field canvas_lines string[]  the root's last painted canvas — the pre-mirror ground truth a subwin restores from
---@field targets table<any, FlushTarget>  all flush targets: the root (keyed by the host) plus one per live container boundary (keyed by its fiber)
---@field root_target FlushTarget  the root's target record (tree/subwins/canvas_lines above alias its fields)
---@field take_damage fun(fiber: Fiber): { top: integer, bot: integer }|nil|false  consume a container target's accumulated damage
---@field drop_target fun(fiber: Fiber)  retire a container target's buffer (its boundary is gone)
---@field set_state fun(fiber: Fiber, name: "hover"|"focus", on: boolean?)  record an interaction state (structural style overrides only)

-- Construct a fresh inline HostConfig around its own scratch buffer.
---@param opts InlineHostOpts
---@return InlineHost
function M.new(opts)
	theme.apply()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].modifiable = false
	visualsel.mark(bufnr) -- guard Visual-mode $ against the off-screen-newline right-scroll

	---@type Fiber|nil  the most recently committed root, so relayout can re-flush
	local last_root = nil

	-- Active interaction states per fiber ({ hover?, focus? }), set by the
	-- interaction layers (interact.lua, subwin.lua) — only for STRUCTURAL
	-- overrides, which must flow through layout; hl-only overrides paint as
	-- overlay extmarks and never come through here. Weak keys: unmounted
	-- fibers drop out on their own.
	local states = setmetatable({}, { __mode = "k" })

	---@type InlineHost
	local host

	-- One flush target per buffer: the root plus one per live container
	-- boundary. Each holds the retained per-buffer state of the incremental
	-- pipeline:
	--   prev_lines/prev_hl_rows  the previous frame's canvas — lines plus hl
	--        spans grouped per row. The damage diff runs canvas-vs-canvas,
	--        never against the buffer: the buffer legitimately diverges
	--        wherever subwin mirrors wrote over it, and those rows must
	--        survive an unrelated splice.
	--   canvas  the persistent cell grid the previous frame was painted on.
	--        While the width holds and the frame doesn't shrink, flushes
	--        repaint only changed subtrees onto it (render.update) — taller
	--        frames grow it in place; a width change or a shrink starts over
	--        with a fresh full paint.
	--   pending  damage accumulated since the subwin manager last consumed it
	--        via host.take_damage ("all" | "none" | { top, bot }) — a
	--        container's manager doesn't exist until its float does, so damage
	--        must survive flushes nobody synced.
	---@class FlushTarget
	---@field bufnr integer
	---@field tree table|nil       the target's last laid-out tree (buffer coordinates)
	---@field subwins table[]      its laid-out subwindow leaves (document order)
	---@field canvas_lines string[]  the last painted canvas — the pre-mirror ground truth
	---@field pending "all"|"none"|{ top: integer, bot: integer }
	---@field dead boolean|nil     the boundary is gone; drop_target retires the buffer

	-- Keyed by the container's fiber; the root target is keyed by `host`.
	---@type table<any, FlushTarget>
	local targets = {}

	---@param spans { row: integer, start_col: integer, end_col: integer, hl: string }[]
	---@param nrows integer
	---@return table[][] per-row span arrays (canvas spans come out row-ordered)
	local function group_by_row(spans, nrows)
		local rows = {}
		for i = 1, nrows do
			rows[i] = {}
		end
		for _, s in ipairs(spans) do
			local r = rows[s.row + 1]
			r[#r + 1] = s
		end
		return rows
	end

	---@param i integer 1-based row in a; j 1-based row in b
	local function rows_equal(la, ha, i, lb, hb, j)
		if la[i] ~= lb[j] then
			return false
		end
		local a, b = ha[i], hb[j]
		if #a ~= #b then
			return false
		end
		for k = 1, #a do
			if a[k].start_col ~= b[k].start_col or a[k].end_col ~= b[k].end_col or a[k].hl ~= b[k].hl then
				return false
			end
		end
		return true
	end

	-- Subtree memoization state: the tick the last flush saw (fiber._node holds
	-- each fiber's memoized node) and the size it flushed at.
	local last_flush_tick = 0
	---@type { width: integer, height: integer|nil }|nil
	local last_size = nil

	-- Can the whole flush be skipped? Only when nothing in the fiber tree
	-- changed (root tree_tick — renders and set_state flips both bubble to
	-- it; container subtrees bubble through their boundary fiber), the size is
	-- the same, and no auto-sized raw_buffer's LIVE line count drifted in ANY
	-- target (buffers change without any fiber rendering).
	---@param size { width: integer, height: integer|nil }
	---@return boolean
	local function clean_frame(size)
		local root = targets[host]
		if not (root.prev_lines and root.tree and last_size) then
			return false
		end
		if (last_root.tree_tick or 0) > last_flush_tick then
			return false
		end
		if size.width ~= last_size.width or size.height ~= last_size.height then
			return false
		end
		for _, target in pairs(targets) do
			for _, node in ipairs(target.subwins or {}) do
				if node._rb_count and rb_count(node.props or {}) ~= node._rb_count then
					return false
				end
			end
		end
		return true
	end

	-- Accumulate a flush's damage into the target's pending slot (consumed by
	-- the subwin manager via host.take_damage).
	---@param target FlushTarget
	---@param damage { top: integer, bot: integer }|nil
	local function note_damage(target, damage)
		if damage == nil or target.pending == "all" then
			return
		end
		if target.pending == "none" then
			target.pending = { top = damage.top, bot = damage.bot }
		else
			target.pending.top = math.min(target.pending.top, damage.top)
			target.pending.bot = math.max(target.pending.bot, damage.bot)
		end
	end

	-- Write `canvas_lines`/`hl_rows` into the target's buffer: the minimal
	-- splice against the previous frame — equal head + equal tail bracket the
	-- one range that gets written. Marks in the range are cleared BEFORE
	-- set_lines (afterwards the edit would have relocated them out of it);
	-- marks outside the range survive, shifting with the edit when the row
	-- count changes. Returns the damage — nil when nothing changed, else
	-- { top, bot } 0-based inclusive rows of the new frame (bot < top: pure
	-- deletion at `top`).
	---@param target FlushTarget
	---@param canvas_lines string[]
	---@param hl_rows table[][]
	---@return { top: integer, bot: integer }|nil damage
	local function splice(target, canvas_lines, hl_rows)
		local buf = target.bufnr
		local prev_lines, prev_hl_rows = target.prev_lines, target.prev_hl_rows
		---@type { top: integer, bot: integer }|nil
		local damage
		if not prev_lines then
			damage = { top = 0, bot = #canvas_lines - 1 }
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, canvas_lines)
			vim.bo[buf].modifiable = false
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
			for _, row in ipairs(hl_rows) do
				for _, s in ipairs(row) do
					vim.api.nvim_buf_set_extmark(buf, ns, s.row, s.start_col, {
						end_col = s.end_col,
						hl_group = s.hl,
					})
				end
			end
		else
			local old_n, new_n = #prev_lines, #canvas_lines
			local n = math.min(old_n, new_n)
			local head = 0 -- rows equal from the top
			while head < n and rows_equal(prev_lines, prev_hl_rows, head + 1, canvas_lines, hl_rows, head + 1) do
				head = head + 1
			end
			if head < n or old_n ~= new_n then
				local tail = 0 -- rows equal from the bottom, not overlapping the head
				while
					tail < n - head
					and rows_equal(prev_lines, prev_hl_rows, old_n - tail, canvas_lines, hl_rows, new_n - tail)
				do
					tail = tail + 1
				end
				local old_end, new_end = old_n - tail, new_n - tail -- exclusive
				vim.api.nvim_buf_clear_namespace(buf, ns, head, old_end)
				local slice = {}
				for i = head + 1, new_end do
					slice[#slice + 1] = canvas_lines[i]
				end
				-- Preserve the cursor's DISPLAY column across the write. set_lines
				-- keeps the byte column, so an animated line whose glyphs change
				-- UTF-8 length (same display width) drags a resting cursor as bytes
				-- shift under it (weave's water indicator). Capture every showing
				-- window whose cursor sits on a rewritten line; restore below. Only
				-- for same-count splices, where line indices don't move.
				local pinned
				if old_n == new_n then
					for _, win in ipairs(vim.fn.win_findbuf(buf)) do
						local pos = vim.api.nvim_win_get_cursor(win)
						local r = pos[1] - 1
						if r >= head and r < old_end then
							local line = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
							pinned = pinned or {}
							pinned[#pinned + 1] = { win = win, row = pos[1], cell = width.str(line:sub(1, pos[2])) }
						end
					end
				end
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, head, old_end, false, slice)
				vim.bo[buf].modifiable = false
				for _, p in ipairs(pinned or {}) do
					local line = vim.api.nvim_buf_get_lines(buf, p.row - 1, p.row, false)[1] or ""
					local col = width.cell_to_byte(line, p.cell)
					if col ~= vim.api.nvim_win_get_cursor(p.win)[2] then
						pcall(vim.api.nvim_win_set_cursor, p.win, { p.row, col })
					end
				end
				for i = head + 1, new_end do
					for _, s in ipairs(hl_rows[i]) do
						vim.api.nvim_buf_set_extmark(buf, ns, s.row, s.start_col, {
							end_col = s.end_col,
							hl_group = s.hl,
						})
					end
				end
				damage = { top = head, bot = new_end - 1 }
			end
		end
		target.prev_lines, target.prev_hl_rows = canvas_lines, hl_rows
		target.canvas_lines = canvas_lines
		return damage
	end

	-- Paint the (already laid-out) tree and write it into the target's buffer.
	---@param target FlushTarget
	---@param tree table
	---@param w integer
	---@param h integer
	---@return { top: integer, bot: integer }|nil damage
	local function flush_target(target, tree, w, h)
		local canvas = target.canvas
		local canvas_lines, hl_rows = {}, {}
		if canvas and canvas.w == w and h >= canvas.h and target.prev_lines then
			-- Incremental frame: repaint only changed subtrees on the
			-- persistent canvas, then patch the retained line/span arrays for
			-- the touched rows. Clean rows keep their very string/table
			-- objects, so the splice diff equates them by identity.
			-- A TALLER frame (scroll mode appending at the tail) grows the
			-- canvas in place rather than starting over; the gained rows are
			-- virgin and always extracted (they exist in no retained array).
			local grown_from = canvas.h
			if h > canvas.h then
				canvas:grow(h)
			end
			local dirty = render.update(canvas, tree)
			for i = 1, h do
				canvas_lines[i], hl_rows[i] = target.prev_lines[i], target.prev_hl_rows[i]
			end
			for y = grown_from, h - 1 do
				dirty[#dirty + 1] = y -- may repeat a repainted row; extraction is idempotent
			end
			for _, y in ipairs(dirty) do
				canvas_lines[y + 1] = canvas:line(y + 1)
				hl_rows[y + 1] = canvas:row_spans(y + 1)
			end
		else
			-- Size changed (or first paint): fresh canvas, full paint.
			canvas = render.paint(tree, w, h)
			target.canvas = canvas
			canvas_lines = canvas:lines()
			hl_rows = group_by_row(canvas:highlights(), h)
		end
		return splice(target, canvas_lines, hl_rows)
	end

	-- Rebuild, lay out, paint and write the committed tree at the current
	-- size — the root target first, then every container target its tree
	-- (transitively) holds, parent before child so a child's constraint comes
	-- from its freshly laid-out boundary rect.
	local function flush()
		if not last_root or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local size = opts.get_size()
		if clean_frame(size) then
			-- identical tree at the identical size: no canvas can differ.
			-- on_flush still runs — subwin float geometry is window state, not
			-- canvas state (and damage nil tells it nothing changed underneath).
			if opts.on_flush then
				opts.on_flush(nil)
			end
			return
		end

		local ctx = { states = states, last_tick = last_flush_tick }
		local tree = build_node(last_root, ctx)
		local root_target = targets[host]
		local seen = { [host] = true }

		---@param key any     target key (the container fiber; `host` for the root)
		---@param t_tree table  the target's tree (a container node's `inner`)
		---@param cw integer  constraint width
		---@param ch integer|nil  constraint height; nil = content height (scroll)
		---@return { top: integer, bot: integer }|nil damage
		local function process(key, t_tree, cw, ch)
			local target = targets[key]
			if not target then
				local buf = vim.api.nvim_create_buf(false, true)
				vim.bo[buf].modifiable = false
				visualsel.mark(buf) -- same Visual-mode $ guard for container canvases
				target = { bufnr = buf, pending = "all", subwins = {}, canvas_lines = {} }
				targets[key] = target
			end
			layout.compute(t_tree, { width = cw, height = ch })
			local damage = flush_target(target, t_tree, cw, ch or t_tree.size.h)
			note_damage(target, damage)
			target.tree = t_tree
			local subs = {}
			collect_subwins(t_tree, subs)
			target.subwins = subs
			for _, node in ipairs(subs) do
				if node.inner then
					seen[node.fiber] = true
					local c = node.content
					local props = node.props or {}
					-- explicit "fixed" lays the content out at exactly the
					-- viewport height (grow/justify fill it); default is scroll —
					-- content height, the float a native viewport over it
					local fixed = props.mode == "fixed"
					-- Content fills the FULL width. The Visual-mode trailing-newline
					-- right-scroll (which a leftcol pin can't win) is handled instead by
					-- the `selection=old` guard on canvas buffers (see visualsel.lua) — so
					-- no column is reserved here, and scroll_x = false costs no width.
					local cw = math.max(c.w, 1)
					process(node.fiber, node.inner, cw, fixed and math.max(c.h, 1) or nil)
				end
			end
			return damage
		end

		---@type { top: integer, bot: integer }|nil
		local root_damage
		if tree then
			root_damage = process(host, tree, size.width, size.height)
		else
			root_target.canvas = nil
			root_target.tree = nil
			root_target.subwins = {}
			root_damage = splice(root_target, {}, {})
		end
		-- Boundaries gone from this flush: their buffers are retired by
		-- whoever notices first — the subwin manager's destroy (drop_target)
		-- or teardown.
		for key, target in pairs(targets) do
			if not seen[key] then
				target.dead = true
			end
		end
		host.tree = root_target.tree
		host.subwins = root_target.subwins
		host.canvas_lines = root_target.canvas_lines
		last_flush_tick = Fiber.current_tick()
		last_size = { width = size.width, height = size.height }

		if opts.on_flush then
			opts.on_flush(root_damage)
		end
	end

	host = {
		bufnr = bufnr,
		ns = ns,
		tree = nil,
		subwins = {},
		canvas_lines = {},

		create_instance = function(tag)
			if not (CONTAINERS[tag] or LEAVES[tag]) then
				error("fibrous.inline: unknown host primitive '" .. tostring(tag) .. "'")
			end
			return { tag = tag }
		end,

		-- The flush works wholesale from the committed fiber tree, so per-instance
		-- update/destroy have nothing to do.
		update_instance = function() end,
		destroy_instance = function() end,

		commit = function(root_fiber)
			last_root = root_fiber
			flush()
		end,

		relayout = flush,

		-- Flip one interaction state for a fiber. The caller decides when a
		-- relayout is due — set_state only records. The tick stamp keeps the
		-- memo honest: the fiber didn't render, but its resolved style did
		-- change, so its node (and the path above it) must rebuild.
		set_state = function(fiber, name, on)
			local t = Fiber.next_tick()
			fiber.self_tick = t
			Fiber.touch(fiber, t)
			local s = states[fiber]
			if on then
				if not s then
					s = {}
					states[fiber] = s
				end
				s[name] = true
			elseif s then
				s[name] = nil
				if next(s) == nil then
					states[fiber] = nil
				end
			end
		end,

		-- Consume the damage a target accumulated since its manager last
		-- synced: nil = unknown/assume-all, false = nothing, else the merged
		-- spliced row range (the same vocabulary SubwinManager.sync speaks).
		take_damage = function(fiber)
			local target = targets[fiber]
			if not target then
				return false
			end
			local p = target.pending
			target.pending = "none"
			if p == "all" then
				return nil
			end
			if p == "none" then
				return false
			end
			return p
		end,

		-- Retire a container's buffer once its boundary (and float) are gone.
		drop_target = function(fiber)
			local target = targets[fiber]
			if not target then
				return
			end
			targets[fiber] = nil
			if vim.api.nvim_buf_is_valid(target.bufnr) then
				pcall(vim.api.nvim_buf_delete, target.bufnr, { force = true })
			end
		end,

		teardown = function()
			last_root = nil
			host.tree = nil
			host.subwins = {}
			for key, target in pairs(targets) do
				targets[key] = nil
				if vim.api.nvim_buf_is_valid(target.bufnr) then
					pcall(vim.api.nvim_buf_delete, target.bufnr, { force = true })
				end
			end
		end,
	}
	-- The root's own flush target (keyed by the host itself); host.bufnr /
	-- host.tree / host.subwins / host.canvas_lines stay as aliases of it.
	targets[host] = { bufnr = bufnr, pending = "all", subwins = {}, canvas_lines = {} }
	host.targets = targets
	host.root_target = targets[host]
	return host
end

return M
