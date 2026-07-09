-- Transcript-shaped benchmark: the chat/ACP-client workload. ONE long col of
-- heterogeneous entries in a scroll-mode host, where the ops that matter are
-- append-at-tail and grow-the-last-entry (streaming) — each arriving as a
-- store-style mutation: the entries array is reassigned, untouched entry
-- OBJECTS keep their identity. Every entry renders through a `memo = true`
-- child component, so once the reconciler honors the flag the N-1 unchanged
-- entries bail out on shallow-equal props; run before/after to see the delta.
-- Invoked as:
--   make bench-transcript            # default N=1000 entries
--   make bench-transcript BENCH_N=4000
--
-- The pure layout+paint number is the floor the reconciler CANNOT get under
-- while a scroll-mode height change still forces a fresh full-canvas paint
-- (host.lua only repaints incrementally while the canvas size holds).

-- Two axes, kept separate so cross-history trends stay honest. The LIBRARY under
-- test comes from the cwd — bench_history.sh points it at each commit's worktree,
-- so lua/fibrous varies per point. The HARNESS (this script's helpers, e.g.
-- throughput) must NOT: it loads from THIS script's own directory, so the ruler
-- stays pinned while the thing measured changes. (Loading it from the cwd too
-- would make a commit that touched bench/ silently move its own numbers, and
-- leaves the uncommitted working tree — snapshotted as lua/ only — unable to find
-- it at all.)
local root_dir = vim.fn.getcwd()
local harness_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = table.concat({
	root_dir .. "/lua/?.lua",
	root_dir .. "/lua/?/init.lua",
	harness_dir .. "?.lua",
	package.path,
}, ";")

local uv = vim.uv or vim.loop

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local ui = require("fibrous.inline.components")
local throughput = require("throughput")

-- Structured-output mode, identical contract to bench/run.lua: BENCH_JSON=1
-- suppresses the human lines and emits one { label, bench, n, results } object;
-- BENCH_LABEL tags the run. Only the reporting changes — the scenarios are what
-- the history walker measures against every commit's library.
local JSON = (vim.env.BENCH_JSON or "") ~= ""
local LABEL = vim.env.BENCH_LABEL or ""
local RESULTS = {}
local function say(line)
	if not JSON then
		io.write(line)
	end
end
local function record(op, unit, value, extra)
	local r = { op = op, unit = unit, value = value }
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	RESULTS[#RESULTS + 1] = r
end

local function bench(name, iters, fn)
	local ok, err = pcall(fn, 0) -- warmup (JIT + caches)
	if not ok then
		record(name, "ms/op", nil, { iters = iters, error = tostring(err) })
		say(("%-52s ERROR: %s\n"):format(name, tostring(err)))
		return
	end
	collectgarbage("collect")
	local t0 = uv.hrtime()
	for i = 1, iters do
		fn(i)
	end
	local per_op = (uv.hrtime() - t0) / iters / 1e6
	-- Draw throughput: one more op, instrumented, OUTSIDE the timed loop — the
	-- cells written to the buffer, the ssh+tmux draw cost (see bench/throughput).
	local draw = throughput.counting(function()
		fn(iters + 1)
	end)
	record(name, "ms/op", per_op, { iters = iters, cells = draw.cells, writes = draw.writes })
	say(("%-52s %10.3f ms/op %8d cells/op  (%d iters)\n"):format(name, per_op, draw.cells, iters))
end

local WIDTH = 100
local N = tonumber(vim.env.BENCH_N) or 1000

-- ~2 wrapped lines of prose at WIDTH; tool entries add a border + title row.
local PROSE = "I looked at the failing spec and the assertion is comparing byte columns "
	.. "against display cells, which diverges as soon as the line holds a multibyte "
	.. "character; the fix is to translate through cell_to_byte at the boundary."

local function make_entry(id, extra)
	return {
		id = id,
		kind = id % 3 == 0 and "tool" or "agent",
		title = ("tool_%d (lua/module_%d.lua)"):format(id, id),
		text = PROSE .. (extra or ""),
	}
end

-- One transcript entry; the memo target. Stable function identity so the
-- reconciler's type match holds across list re-renders.
local function Entry(_, props)
	local e = props.entry
	if e.kind == "tool" then
		return {
			comp = ui.col,
			props = { style = { border = "single", padding = { x = 1 } } },
			children = {
				{ comp = ui.label, props = { text = e.title, style = { text_hl = "Title" } } },
				{ comp = ui.paragraph, props = { text = e.text } },
			},
		}
	end
	return { comp = ui.paragraph, props = { text = e.text } }
end

local function initial_entries(n)
	local entries = {}
	for i = 1, n do
		entries[i] = make_entry(i)
	end
	return entries
end

-- Reassign-not-mutate, the store discipline: a fresh array every time, entry
-- objects reused except the ones the mutation replaces.
local function copy(entries)
	local out = {}
	for i = 1, #entries do
		out[i] = entries[i]
	end
	return out
end

-- The transcript list. Its use_state owns the entries array, so every
-- mutation re-renders THIS component — the memo flag on the children is what
-- keeps that from cascading into N entry re-renders.
local function make_transcript(api, seed)
	return function(ctx)
		local s = ctx.use_state(seed)
		api.get, api.set = s.get, s.set
		local entries = s.get()
		local children = {}
		for i, e in ipairs(entries) do
			children[i] = { comp = Entry, props = { entry = e }, memo = true }
		end
		return { comp = ui.col, props = { gap = 1 }, children = children }
	end
end

local function scroll_host()
	return inline_host.new({
		get_size = function()
			return { width = WIDTH }
		end,
	})
end

say(("transcript benchmarks — N = %d entries\n\n"):format(N))

---------------------------------------------------------------------------
-- The paint floor: layout + full fresh paint at transcript size, no
-- reconciler, no buffer. Until the canvas can grow in place, every
-- height-changing commit (append, streamed line) pays at least this.
---------------------------------------------------------------------------

do
	local function pure_tree()
		local children = {}
		for i = 1, N do
			local e = make_entry(i)
			if e.kind == "tool" then
				children[i] = {
					kind = "col",
					props = { border = "single", padding = { x = 1 } },
					children = {
						{ kind = "text", props = { text_hl = "Title" }, text = e.title },
						{ kind = "text", props = { wrap = true }, text = e.text },
					},
				}
			else
				children[i] = { kind = "text", props = { wrap = true }, text = e.text }
			end
		end
		return { kind = "col", props = { gap = 1 }, children = children }
	end
	bench("pure layout+paint at transcript size", 10, function()
		local tree = pure_tree()
		layout.compute(tree, { width = WIDTH })
		render.paint(tree, WIDTH, tree.size.h)
	end)
end

---------------------------------------------------------------------------
-- Reconciler + host, scroll mode
---------------------------------------------------------------------------

bench("mount (create_root + first commit + teardown)", 5, function()
	local host = scroll_host()
	local root = runtime.create_root(make_transcript({}, initial_entries(N)), {}, { host = host })
	root:render()
	root:unmount()
end)

do
	local host = scroll_host()
	local api = {}
	local root = runtime.create_root(make_transcript(api, initial_entries(N)), {}, { host = host })
	root:render()

	bench("append one entry", 30, function()
		local next_entries = copy(api.get())
		next_entries[#next_entries + 1] = make_entry(#next_entries + 1)
		api.set(next_entries)
	end)

	bench("stream tick (grow the last entry)", 50, function(i)
		local cur = api.get()
		local next_entries = copy(cur)
		local last = cur[#cur]
		next_entries[#cur] = make_entry(last.id, (" streamed-%d"):format(i):rep(8))
		api.set(next_entries)
	end)

	-- Same-size mutation mid-list: no height change, so the incremental
	-- canvas path stays live — this isolates the reconciler's share.
	bench("replace one mid-transcript entry (same size)", 50, function(i)
		local cur = api.get()
		local next_entries = copy(cur)
		local mid = math.floor(#cur / 2)
		next_entries[mid] = make_entry(cur[mid].id, nil)
		api.set(next_entries)
	end)

	root:unmount()
end

if JSON then
	io.write(vim.json.encode({ label = LABEL, bench = "transcript", n = N, results = RESULTS }) .. "\n")
else
	io.write("\ndone\n")
end
