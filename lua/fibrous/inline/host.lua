-- The inline HostConfig (tracker "NEW UI HOST" task 3): the concrete bridge
-- the reconciler drives for the inline UI host. Rather than giving every
-- leaf its own window, the WHOLE committed fiber tree becomes one layout
-- tree (layout.compute), one painted canvas (render.paint), and one flush into
-- a single host-owned scratch buffer — full lines plus extmark highlight
-- spans. A mount target (inline/mount.lua) shows that buffer in the root float
-- and owns all window concerns; this module never touches windows.
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

local M = {}

local CONTAINERS = { col = true, row = true }
-- text_input is a subwindow leaf: laid out (and its border/background painted)
-- inline like any node, but its content box is covered by a real float that
-- subwin.lua manages — the node carries `subwin` so the manager can find it.
local LEAVES = { text = true, text_input = true, raw_buffer = true }

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
		return child and build_node(child, ctx) or nil
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
	end
	attach_style(node, ctx.states)
	-- Tier B (incremental paint) bookkeeping, stored only off the fast path:
	-- `_keep` marks a node rebuilt ONLY because a descendant changed (its own
	-- visual is intact — the paint can descend instead of repainting it), and
	-- `_old_rect` remembers where its previous incarnation sat.
	if prev then
		if (fiber.self_tick or 0) <= ctx.last_tick then
			node._keep = true
		end
		node._old_rect = prev.rect
	end
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
---@field tree table|nil  the last laid-out tree (rects are buffer coordinates)
---@field subwins table[] laid-out subwindow nodes of the last flush (document order)
---@field canvas_lines string[]  the last painted canvas — the pre-mirror ground truth a subwin restores from
---@field set_state fun(fiber: Fiber, name: "hover"|"focus", on: boolean?)  record an interaction state (structural style overrides only)

-- Construct a fresh inline HostConfig around its own scratch buffer.
---@param opts InlineHostOpts
---@return InlineHost
function M.new(opts)
	theme.apply()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].modifiable = false

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

	-- The previous frame's canvas: lines plus hl spans grouped per row. The
	-- damage diff runs canvas-vs-canvas, never against the buffer — the buffer
	-- legitimately diverges wherever subwin mirrors wrote over it, and those
	-- rows must survive an unrelated splice.
	---@type string[]|nil
	local prev_lines = nil
	---@type table[][]
	local prev_hl_rows = {}
	-- The persistent cell grid the previous frame was painted on. While the
	-- size holds, flushes repaint only changed subtrees onto it
	-- (render.update); a size change starts over with a fresh full paint.
	---@type Canvas|nil
	local canvas = nil

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
	-- it), the size is the same, and no auto-sized raw_buffer's LIVE line
	-- count drifted (buffers change without any fiber rendering).
	---@param size { width: integer, height: integer|nil }
	---@return boolean
	local function clean_frame(size)
		if not (prev_lines and host.tree and last_size) then
			return false
		end
		if (last_root.tree_tick or 0) > last_flush_tick then
			return false
		end
		if size.width ~= last_size.width or size.height ~= last_size.height then
			return false
		end
		for _, node in ipairs(host.subwins) do
			if node._rb_count and rb_count(node.props or {}) ~= node._rb_count then
				return false
			end
		end
		return true
	end

	-- Rebuild, lay out, paint and write the committed tree at the current size.
	local function flush()
		if not last_root or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local size = opts.get_size()
		if clean_frame(size) then
			-- identical tree at the identical size: the canvas cannot differ.
			-- on_flush still runs — subwin float geometry is window state, not
			-- canvas state (and damage nil tells it nothing changed underneath).
			if opts.on_flush then
				opts.on_flush(nil)
			end
			return
		end

		local ctx = { states = states, last_tick = last_flush_tick }
		local tree = build_node(last_root, ctx)
		local canvas_lines, hl_rows = {}, {}
		local subwins = {}
		if tree then
			layout.compute(tree, { width = size.width, height = size.height })
			local w, h = size.width, size.height or tree.size.h
			if canvas and canvas.w == w and canvas.h == h and prev_lines then
				-- Incremental frame: repaint only changed subtrees on the
				-- persistent canvas, then patch the retained line/span arrays for
				-- the touched rows. Clean rows keep their very string/table
				-- objects, so the splice diff below equates them by identity.
				local dirty = render.update(canvas, tree)
				for i = 1, h do
					canvas_lines[i], hl_rows[i] = prev_lines[i], prev_hl_rows[i]
				end
				for _, y in ipairs(dirty) do
					canvas_lines[y + 1] = canvas:line(y + 1)
					hl_rows[y + 1] = canvas:row_spans(y + 1)
				end
			else
				-- Size changed (or first paint): fresh canvas, full paint.
				canvas = render.paint(tree, w, h)
				canvas_lines = canvas:lines()
				hl_rows = group_by_row(canvas:highlights(), h)
			end
			collect_subwins(tree, subwins)
		else
			canvas = nil
		end
		host.tree = tree
		host.subwins = subwins
		last_flush_tick = Fiber.current_tick()
		last_size = { width = size.width, height = size.height }

		-- Minimal splice against the previous frame: equal head + equal tail
		-- bracket the one range that gets written. Marks in the range are cleared
		-- BEFORE set_lines (afterwards the edit would have relocated them out of
		-- it); marks outside the range survive, shifting with the edit when the
		-- row count changes.
		---@type { top: integer, bot: integer }|nil
		local damage
		if not prev_lines then
			damage = { top = 0, bot = #canvas_lines - 1 }
			vim.bo[bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, canvas_lines)
			vim.bo[bufnr].modifiable = false
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			for _, row in ipairs(hl_rows) do
				for _, s in ipairs(row) do
					vim.api.nvim_buf_set_extmark(bufnr, ns, s.row, s.start_col, {
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
				vim.api.nvim_buf_clear_namespace(bufnr, ns, head, old_end)
				local slice = {}
				for i = head + 1, new_end do
					slice[#slice + 1] = canvas_lines[i]
				end
				vim.bo[bufnr].modifiable = true
				vim.api.nvim_buf_set_lines(bufnr, head, old_end, false, slice)
				vim.bo[bufnr].modifiable = false
				for i = head + 1, new_end do
					for _, s in ipairs(hl_rows[i]) do
						vim.api.nvim_buf_set_extmark(bufnr, ns, s.row, s.start_col, {
							end_col = s.end_col,
							hl_group = s.hl,
						})
					end
				end
				damage = { top = head, bot = new_end - 1 }
			end
		end
		prev_lines, prev_hl_rows = canvas_lines, hl_rows
		host.canvas_lines = canvas_lines

		if opts.on_flush then
			opts.on_flush(damage)
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

		teardown = function()
			last_root = nil
			host.tree = nil
			host.subwins = {}
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_delete(bufnr, { force = true })
			end
		end,
	}
	return host
end

return M
