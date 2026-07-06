-- Canvas damage tracking: a flush no longer rewrites the whole buffer. The
-- host retains the previous frame's canvas (lines + hl spans), diffs the new
-- frame against it, and applies one minimal splice — a ranged namespace clear
-- (BEFORE the write, while the old marks are still where they were put), one
-- ranged set_lines, and extmarks for the spliced rows only. `on_flush`
-- receives the damage: nil when nothing changed, else { top, bot } (0-based
-- inclusive buffer rows of the new frame; bot < top marks a pure deletion).
--
-- The subwin manager uses the damage to decide per widget whether the canvas
-- under it was clobbered: a flush that misses a widget's box leaves its mirror
-- and transcription marks alone. Because the flush no longer repaints
-- wholesale, whoever painted over the canvas must also clean up after itself:
-- a widget restores the canvas under its box when it is destroyed or its box
-- changes, and a flush that blanks a FOCUSED widget's box invalidates its
-- extraction memo so leaving the widget repairs the mirror.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local mount = require("fibrous.inline.mount")

local col = { __host = "col" }
local row = { __host = "row" }
local text = { __host = "text" }
local text_input = { __host = "text_input" }
local raw_buffer = { __host = "raw_buffer" }

local function lines_of(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- All extmarks in the buffer (every namespace), keyed comparable.
local function marks_of(bufnr)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
		out[#out + 1] = { id = m[1], row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
	end
	return out
end

-- The single mark with hl group `hl`, or nil.
local function mark_with_hl(bufnr, hl)
	for _, m in ipairs(marks_of(bufnr)) do
		if m.hl == hl then
			return m
		end
	end
	return nil
end

-- The (single) subwindow float anchored to the root float, or nil.
local function subwin_of(handle)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative == "win" and cfg.win == handle.winid then
			return w
		end
	end
	return nil
end

describe("inline.host damage tracking", function()
	it("a no-change relayout writes nothing and keeps every extmark", function()
		local function App()
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "aa", style = { text_hl = "Title" } } },
					{ comp = text, props = { text = "bb" } },
				},
			}
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()
		local tick = vim.api.nvim_buf_get_changedtick(host.bufnr)
		local before = marks_of(host.bufnr)

		host.relayout()

		assert.equal(tick, vim.api.nvim_buf_get_changedtick(host.bufnr))
		assert.same(before, marks_of(host.bufnr)) -- same ids: not cleared + re-added
		root:unmount()
	end)

	it("a one-row change splices only that row; marks elsewhere keep their ids", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "head", style = { text_hl = "Title" } } },
					{ comp = text, props = { text = "n " .. s.get(), style = { text_hl = "Constant" } } },
					{ comp = text, props = { text = "tail", style = { text_hl = "Comment" } } },
				},
			}
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 5 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()
		local head_id = mark_with_hl(host.bufnr, "Title").id
		local tail_id = mark_with_hl(host.bufnr, "Comment").id
		local events = {}
		vim.api.nvim_buf_attach(host.bufnr, false, {
			on_lines = function(_, _, _, first, last, last_new)
				events[#events + 1] = { first, last, last_new }
			end,
		})

		setter.set(1)

		assert.same({ { 1, 2, 2 } }, events) -- exactly the damaged row
		assert.same({ "head ", "n 1  ", "tail " }, lines_of(host.bufnr))
		assert.equal(head_id, mark_with_hl(host.bufnr, "Title").id)
		assert.equal(tail_id, mark_with_hl(host.bufnr, "Comment").id)
		assert.same({ row = 1, col = 0, end_col = 3 }, {
			row = mark_with_hl(host.bufnr, "Constant").row,
			col = mark_with_hl(host.bufnr, "Constant").col,
			end_col = mark_with_hl(host.bufnr, "Constant").end_col,
		})
		root:unmount()
	end)

	it("a row-count change stays equivalent to a full repaint", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state(false)
			setter = s
			local children = {
				{ comp = text, props = { text = "head", style = { text_hl = "Title" } } },
			}
			if s.get() then
				children[#children + 1] = { comp = text, props = { text = "mid" } }
			end
			children[#children + 1] = { comp = text, props = { text = "tail", style = { text_hl = "Comment" } } }
			return { comp = col, props = {}, children = children }
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 5 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()

		setter.set(true)

		assert.same({ "head ", "mid  ", "tail " }, lines_of(host.bufnr))
		local tail = mark_with_hl(host.bufnr, "Comment")
		assert.equal(2, tail.row) -- the surviving mark moved with its line

		setter.set(false)

		assert.same({ "head ", "tail " }, lines_of(host.bufnr))
		assert.equal(1, mark_with_hl(host.bufnr, "Comment").row)
		root:unmount()
	end)

	it("appending to a memo'd list splices only the appended rows (growth path)", function()
		-- The transcript hot path end to end: scroll mode, the list re-renders
		-- with one more entry, the canvas GROWS in place — rows above the append
		-- must not be rewritten and their marks must keep their ids.
		local function Entry(_, props)
			return { comp = text, props = { text = props.item.text, style = { text_hl = props.item.hl } } }
		end
		local setter
		local function App(ctx)
			local s = ctx.use_state({ { text = "aaa", hl = "Title" }, { text = "bbb", hl = "Comment" } })
			setter = s
			local children = {}
			for i, item in ipairs(s.get()) do
				children[i] = { comp = Entry, props = { item = item }, memo = true }
			end
			return { comp = col, props = {}, children = children }
		end
		local damages = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
			on_flush = function(damage)
				damages[#damages + 1] = damage == nil and "nil" or (damage.top .. ":" .. damage.bot)
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()
		local head_id = mark_with_hl(host.bufnr, "Title").id
		local events = {}
		vim.api.nvim_buf_attach(host.bufnr, false, {
			on_lines = function(_, _, _, first, last, last_new)
				events[#events + 1] = { first, last, last_new }
			end,
		})

		local cur = setter.get()
		setter.set({ cur[1], cur[2], { text = "ccc", hl = "Constant" } })

		assert.same({ { 2, 2, 3 } }, events) -- one write: the appended row
		assert.same({ "aaa ", "bbb ", "ccc " }, lines_of(host.bufnr))
		assert.same({ "0:1", "2:2" }, damages)
		assert.equal(head_id, mark_with_hl(host.bufnr, "Title").id)
		assert.equal(2, mark_with_hl(host.bufnr, "Constant").row)
		root:unmount()
	end)

	it("replacing a widget with a narrower sibling clears the cells it vacated", function()
		-- The TODO pattern: a bordered widget is the last child; a state change
		-- inserts a NARROWER sibling at its index, so the positional reconciler
		-- unmounts the widget's fiber (type change) and remounts it one row down.
		-- The incremental painter must blank the removed widget's old box — the
		-- new narrow sibling covers only part of it, and the parent col descends
		-- (chrome intact) rather than repainting wholesale. Reference: a fresh
		-- full paint straight at the target state.
		local function make(initial)
			local setter
			local function App(ctx)
				local s = ctx.use_state(initial)
				setter = s
				local children = { { comp = text, props = { text = "head" } } }
				for i = 1, s.get() do
					children[#children + 1] = { comp = text, props = { text = "item" .. i } }
				end
				children[#children + 1] = { comp = text_input, props = { style = { border = true } } }
				return { comp = col, props = { gap = 1 }, children = children }
			end
			local host = inline_host.new({
				get_size = function()
					return { width = 12, height = 12 }
				end,
			})
			local root = runtime.create_root(App, {}, { host = host }):render()
			return host, root, setter
		end

		local h1, r1, set1 = make(0)
		set1.set(1) -- shift the bordered input down, a narrow text takes its old row

		local h2, r2 = make(1) -- the same tree, painted from scratch
		assert.same(lines_of(h2.bufnr), lines_of(h1.bufnr))

		r1:unmount()
		r2:unmount()
	end)

	it("on_flush reports the damage: full on first paint, the row range after, nil on no change", function()
		local damages = {}
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "head" } },
					{ comp = text, props = { text = "n " .. s.get() } },
					{ comp = text, props = { text = "tail" } },
				},
			}
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 5 }
			end,
			on_flush = function(damage)
				damages[#damages + 1] = damage == nil and "nil" or (damage.top .. ":" .. damage.bot)
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()

		setter.set(1)
		host.relayout()

		assert.same({ "0:2", "1:1", "nil" }, damages)
		root:unmount()
	end)
end)

describe("inline.subwin damage tracking", function()
	-- A sub buffer with content and a persistent hl extmark set BEFORE mount, so
	-- the first extraction transcribes it.
	local function make_buf()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi" })
		local ns = vim.api.nvim_create_namespace("damage_spec_hl")
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 2, hl_group = "ErrorMsg" })
		return buf
	end

	it("a flush that misses the widget's box leaves its extraction untouched", function()
		local buf = make_buf()
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "count " .. s.get() } },
					{ comp = raw_buffer, props = { bufnr = buf, height = 1, wrap = false } },
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 4 })
		local before = mark_with_hl(handle.bufnr, "ErrorMsg")
		assert.is_not_nil(before)
		assert.equal("hi        ", lines_of(handle.bufnr)[2])
		local tick = vim.api.nvim_buf_get_changedtick(handle.bufnr)

		setter.set(1) -- damages row 0 only

		-- exactly ONE write: the splice. No mirror rewrite, no transcription.
		assert.equal(tick + 1, vim.api.nvim_buf_get_changedtick(handle.bufnr))
		assert.equal("count 1   ", lines_of(handle.bufnr)[1])
		assert.equal("hi        ", lines_of(handle.bufnr)[2]) -- mirror untouched
		local after = mark_with_hl(handle.bufnr, "ErrorMsg")
		assert.equal(before.id, after.id) -- not cleared + re-added
		assert.equal(1, after.row)

		handle.unmount()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("a no-change relayout through the mount leaves widgets fully alone", function()
		-- Regression: the mount's on_flush wrapper must map damage nil → sync(false).
		-- (`x == nil and false or x` can never yield false — it silently forced a
		-- full re-extraction of every widget on every clean frame.)
		local buf = make_buf()
		local function App()
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "top" } },
					{ comp = raw_buffer, props = { bufnr = buf, height = 1, wrap = false } },
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 4 })
		local tick = vim.api.nvim_buf_get_changedtick(handle.bufnr)

		handle.relayout()
		handle.relayout()

		-- no mirror rewrite, no transcription: not one buffer write
		assert.equal(tick, vim.api.nvim_buf_get_changedtick(handle.bufnr))

		handle.unmount()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("a flush that damages the widget's rows re-extracts the mirror over the splice", function()
		local buf = make_buf()
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = row,
				props = {},
				children = {
					{ comp = text, props = { text = "n=" .. s.get() } },
					{ comp = raw_buffer, props = { bufnr = buf, height = 1, width = 4, wrap = false } },
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 3 })
		assert.truthy(lines_of(handle.bufnr)[1]:find("hi", 1, true))

		setter.set(1) -- same row as the widget: the splice blanks its box

		local line = lines_of(handle.bufnr)[1]
		assert.truthy(line:find("n=1", 1, true))
		assert.truthy(line:find("hi", 1, true)) -- mirror repaired after the splice
		assert.is_not_nil(mark_with_hl(handle.bufnr, "ErrorMsg"))

		handle.unmount()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("unmounting a widget restores the canvas under its box", function()
		local buf = make_buf()
		local setter
		local function App(ctx)
			local s = ctx.use_state(true)
			setter = s
			local widget
			if s.get() then
				widget = { comp = raw_buffer, props = { bufnr = buf, height = 1, wrap = false } }
			else
				widget = { comp = text, props = { text = "" } } -- same-size blank: no canvas damage
			end
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "top" } },
					widget,
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 6, height = 3 })
		assert.equal("hi    ", lines_of(handle.bufnr)[2])

		setter.set(false)

		assert.equal("      ", lines_of(handle.bufnr)[2]) -- no stale mirror text
		assert.is_nil(mark_with_hl(handle.bufnr, "ErrorMsg"))

		handle.unmount()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("shrinking a widget's box restores the orphaned rows", function()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
		local setter
		local function App(ctx)
			local s = ctx.use_state(3)
			setter = s
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "top" } },
					{ comp = raw_buffer, props = { bufnr = buf, height = s.get(), wrap = false } },
				},
			}
		end
		-- fixed height: the rows after the widget stay blank in both frames, so
		-- the shrink produces NO canvas damage — only the restore can clean row 4
		local handle = mount.floating(App, {}, { width = 6, height = 5 })
		assert.same({ "top   ", "l1    ", "l2    ", "l3    ", "      " }, lines_of(handle.bufnr))

		setter.set(2)

		assert.same({ "top   ", "l1    ", "l2    ", "      ", "      " }, lines_of(handle.bufnr))

		handle.unmount()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("a damaging flush while the widget is focused repairs the mirror on leave", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = row,
				props = {},
				children = {
					{ comp = text, props = { text = "n=" .. s.get() } },
					{ comp = text_input, props = { value = "hi", width = 4 } },
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 3 })
		assert.truthy(lines_of(handle.bufnr)[1]:find("hi", 1, true))

		-- focus the (hidden) float; WinEnter reveals it
		local sub = subwin_of(handle)
		vim.api.nvim_set_current_win(sub)
		setter.set(1) -- damages the widget's row while the float covers it
		vim.api.nvim_set_current_win(handle.winid) -- leave WITHOUT editing

		vim.wait(200, function()
			return (lines_of(handle.bufnr)[1] or ""):find("hi", 1, true) ~= nil
		end)
		local line = lines_of(handle.bufnr)[1]
		assert.truthy(line:find("n=1", 1, true))
		assert.truthy(line:find("hi", 1, true)) -- mirror repaired, not blank

		handle.unmount()
	end)
end)
