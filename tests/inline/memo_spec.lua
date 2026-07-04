-- Subtree-scoped memoization: a scoped state update re-renders one fiber
-- subtree, and the commit pipeline now matches that scope. Fibers carry
-- dirtiness ticks (self_tick = this fiber rendered / state-flipped,
-- tree_tick = anywhere in its subtree, bubbled up through fiber.parent), and
-- build_node reuses the previous flush's node OBJECTS for untouched subtrees.
-- layout.compute memoizes on those objects: measure skips a reused node under
-- the same width constraint, the position pass skips a reused node assigned
-- the same box. A flush with no dirt at all (and the same size) short-circuits
-- before building anything.
--
-- Node identity (rawequal) is the observable for reuse; the fresh-mount
-- oracle guards that memoization never changes what lands in the buffer.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")

local col = { __host = "col" }
local text = { __host = "text" }

local function lines_of(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Extmark spans without ids, canonically sorted — comparable across hosts.
local function spans_of(bufnr)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
		out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
	end
	table.sort(out, function(a, b)
		if a.row ~= b.row then
			return a.row < b.row
		end
		if a.col ~= b.col then
			return a.col < b.col
		end
		if a.end_col ~= b.end_col then
			return a.end_col < b.end_col
		end
		return tostring(a.hl) < tostring(b.hl)
	end)
	return out
end

-- App: a static component subtree, a stateful counter, and a trailing label.
-- `initial` seeds the counter so a fresh mount can reproduce a stepped state.
local function make_app(box, initial, render_count)
	local function Counter(ctx)
		local s = ctx.use_state(initial or 0)
		box.set = s.set
		return { comp = text, props = { text = render_count(s.get()), style = { text_hl = "Constant" } } }
	end
	local function Static()
		return {
			comp = col,
			props = {},
			children = {
				{ comp = text, props = { text = "static", style = { text_hl = "Title" } } },
			},
		}
	end
	return function()
		return {
			comp = col,
			props = {},
			children = {
				{ comp = Static },
				{ comp = Counter },
				{ comp = text, props = { text = "below", style = { text_hl = "Comment" } } },
			},
		}
	end
end

local function count_text(n)
	return "n " .. n
end

describe("inline.host subtree memoization", function()
	it("a scoped update rebuilds only the updated subtree's nodes", function()
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, count_text), {}, { host = host }):render()
		local static_before = host.tree.children[1]
		local counter_before = host.tree.children[2]
		local below_before = host.tree.children[3]

		box.set(1)

		assert.rawequal(static_before, host.tree.children[1])
		assert.rawequal(below_before, host.tree.children[3])
		assert.is_false(rawequal(counter_before, host.tree.children[2]))
		assert.same({ "static  ", "n 1     ", "below   " }, lines_of(host.bufnr))
		root:unmount()
	end)

	it("a no-dirt relayout at the same size reuses the whole tree", function()
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, count_text), {}, { host = host }):render()
		local tree_before = host.tree

		host.relayout()

		assert.rawequal(tree_before, host.tree)
		root:unmount()
	end)

	it("a size-changing scoped update stays equivalent to a fresh mount", function()
		local function grow(n)
			return n == 0 and "one" or "one\ntwo"
		end
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, grow), {}, { host = host }):render()

		box.set(1) -- counter grows a row: everything below shifts

		local fresh_box = {}
		local fresh = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local fresh_root = runtime.create_root(make_app(fresh_box, 1, grow), {}, { host = fresh }):render()

		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("shrinking back re-uses the shifted siblings and still matches a fresh mount", function()
		local function grow(n)
			return n % 2 == 1 and "one\ntwo" or "one"
		end
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, grow), {}, { host = host }):render()

		box.set(1)
		box.set(2) -- back to one row

		local fresh_box = {}
		local fresh = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local fresh_root = runtime.create_root(make_app(fresh_box, 2, grow), {}, { host = fresh }):render()

		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("a width change re-measures reused nodes (memo keys on the constraint)", function()
		local w = 12
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = w }
			end,
		})
		local function App(ctx)
			local s = ctx.use_state(0)
			box.set = s.set
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "the quick fox", wrap = true } },
					{ comp = text, props = { text = "n " .. s.get() } },
				},
			}
		end
		local root = runtime.create_root(App, {}, { host = host }):render()
		assert.same({ "the quick   ", "fox         ", "n 0         " }, lines_of(host.bufnr))

		w = 6
		host.relayout()

		assert.same({ "the   ", "quick ", "fox   ", "n 0   " }, lines_of(host.bufnr))
		root:unmount()
	end)

	-- Incremental paint oracles: the persistent canvas repaints only changed
	-- subtrees (blank the vacated cells, restore ancestor backgrounds, repaint).
	-- Each scenario steps a mounted app and must land byte-identical to a fresh
	-- mount at the final state — lines AND highlight spans.
	it("shorter text in an unchanged rect blanks the leftover cells", function()
		local function txt(n)
			-- same line count; the second line SHRINKS (the stale-cell trap: a
			-- repaint that only writes the new chars would leave "efef")
			return n == 0 and "ab\ncdef" or "abcd\nef"
		end
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, txt), {}, { host = host }):render()

		box.set(1)

		local fresh_box = {}
		local fresh = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local fresh_root = runtime.create_root(make_app(fresh_box, 1, txt), {}, { host = fresh }):render()
		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("a leaf update under a background container keeps the ancestor bg", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state(0)
			setter = s
			return {
				comp = col,
				props = { style = { hl = "Visual", padding = { x = 1 } } },
				children = {
					{ comp = text, props = { text = "n " .. s.get(), style = { text_hl = "Constant" } } },
				},
			}
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()

		setter.set(1)

		local function Fresh()
			return {
				comp = col,
				props = { style = { hl = "Visual", padding = { x = 1 } } },
				children = {
					{ comp = text, props = { text = "n 1", style = { text_hl = "Constant" } } },
				},
			}
		end
		local fresh = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local fresh_root = runtime.create_root(Fresh, {}, { host = fresh }):render()
		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("unmounting a bordered subtree blanks everything it painted", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state(true)
			setter = s
			local children = {
				{ comp = text, props = { text = "head" } },
			}
			if s.get() then
				children[#children + 1] = {
					comp = col,
					props = { style = { border = "single", hl = "Visual" } },
					children = { { comp = text, props = { text = "boxed" } } },
				}
			end
			children[#children + 1] = { comp = text, props = { text = "tail", style = { text_hl = "Comment" } } }
			return { comp = col, props = {}, children = children }
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 9, height = 6 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()

		setter.set(false)

		local function Fresh()
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "head" } },
					{ comp = text, props = { text = "tail", style = { text_hl = "Comment" } } },
				},
			}
		end
		local fresh = inline_host.new({
			get_size = function()
				return { width = 9, height = 6 }
			end,
		})
		local fresh_root = runtime.create_root(Fresh, {}, { host = fresh }):render()
		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("a memo'd list re-render reuses every unchanged entry's node", function()
		-- The transcript shape: the list component's own state holds the entries
		-- array; each entry is a `memo = true` child. Replacing ONE entry object
		-- re-renders the list, but the others bail out of the render entirely —
		-- so their fibers stay clean and build hands back their node objects.
		local function Entry(_, props)
			return { comp = text, props = { text = props.item.text } }
		end
		local setter
		local function App(ctx)
			local s = ctx.use_state({ { text = "aaa" }, { text = "bbb" }, { text = "ccc" } })
			setter = s
			local children = {}
			for i, item in ipairs(s.get()) do
				children[i] = { comp = Entry, props = { item = item }, memo = true }
			end
			return { comp = col, props = {}, children = children }
		end
		local host = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
		})
		local root = runtime.create_root(App, {}, { host = host }):render()
		local first = host.tree.children[1]
		local third = host.tree.children[3]

		local cur = setter.get()
		setter.set({ cur[1], { text = "BBB" }, cur[3] })

		assert.rawequal(first, host.tree.children[1])
		assert.rawequal(third, host.tree.children[3])
		assert.same({ "aaa ", "BBB ", "ccc " }, lines_of(host.bufnr))

		local fresh = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
		})
		local function Fresh()
			return {
				comp = col,
				props = {},
				children = {
					{ comp = text, props = { text = "aaa" } },
					{ comp = text, props = { text = "BBB" } },
					{ comp = text, props = { text = "ccc" } },
				},
			}
		end
		local fresh_root = runtime.create_root(Fresh, {}, { host = fresh }):render()
		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("appending through the grown canvas stays equivalent to a fresh mount", function()
		-- Growth-path oracle: append two entries (the second exercises growing
		-- an ALREADY-grown canvas), then compare byte-for-byte with a fresh
		-- mount at the final state — lines and highlight spans.
		local function Entry(_, props)
			return { comp = text, props = { text = props.item.text, style = { text_hl = props.item.hl } } }
		end
		local function list_app(box, items)
			return function(ctx)
				local s = ctx.use_state(items)
				box.get, box.set = s.get, s.set
				local children = {}
				for i, item in ipairs(s.get()) do
					children[i] = { comp = Entry, props = { item = item }, memo = true }
				end
				return { comp = col, props = { gap = 1 }, children = children }
			end
		end
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
		})
		local seed = { { text = "aaa", hl = "Title" } }
		local root = runtime.create_root(list_app(box, seed), {}, { host = host }):render()

		local one = box.get()
		box.set({ one[1], { text = "bb", hl = "Comment" } })
		local two = box.get()
		box.set({ two[1], two[2], { text = "c", hl = "Constant" } })

		local fresh_box = {}
		local fresh = inline_host.new({
			get_size = function()
				return { width = 4 }
			end,
		})
		local final = {
			{ text = "aaa", hl = "Title" },
			{ text = "bb", hl = "Comment" },
			{ text = "c", hl = "Constant" },
		}
		local fresh_root = runtime.create_root(list_app(fresh_box, final), {}, { host = fresh }):render()
		assert.same(lines_of(fresh.bufnr), lines_of(host.bufnr))
		assert.same(spans_of(fresh.bufnr), spans_of(host.bufnr))
		root:unmount()
		fresh_root:unmount()
	end)

	it("set_state rebuilds the touched fiber's node despite the memo", function()
		local box = {}
		local host = inline_host.new({
			get_size = function()
				return { width = 8 }
			end,
		})
		local root = runtime.create_root(make_app(box, 0, count_text), {}, { host = host }):render()
		-- prime the memo so everything is reusable
		host.relayout()
		local below = host.tree.children[3]

		host.set_state(below.fiber, "hover", true)
		host.relayout()

		assert.is_false(rawequal(below, host.tree.children[3]))
		root:unmount()
	end)
end)
