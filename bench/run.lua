-- Benchmarks for the inline host (tracker "NEW UI HOST" task 8). Invoked as:
--   make bench      (nvim --headless -u NONE -i NONE -l bench/run.lua)
--
-- Perf posture (tracker decision): every commit is a full measure + repaint of
-- the whole tree, and these numbers are the gate for whether that stays
-- acceptable or damage-tracking gets pulled out of the back pocket. Scenarios:
--   * pure layout+paint      the engine alone, no buffer writes
--   * mount                  create_root + first commit + teardown
--   * full re-commit         set_props → every component re-renders + reflush
--   * incremental update     one leaf's use_state set() → scoped re-render,
--                            full reflush (the common interactive path)
--   * scoped leaf update     the state lives in a CHILD component, so the
--                            re-render is one leaf and the number isolates the
--                            commit pipeline (build + layout + paint + write) —
--                            the damage-tracking target
--   * scroll tick            WinScrolled → subwin manager resync only
--   * animation              CPU consumed by ONE live ui.animation embedded
--                            in the page over a real second of event loop —
--                            measured against the idle-loop baseline, once
--                            with a moving frame (every tick commits) and
--                            once with a static one (every tick diff-skips)
--
-- N counts SECTIONS; each section is col{ label, row{ button, checkbox },
-- paragraph }, i.e. ~6 nodes — so N=100 is a ~600-node tree.

local root_dir = vim.fn.getcwd()
package.path = table.concat({
	root_dir .. "/lua/?.lua",
	root_dir .. "/lua/?/init.lua",
	package.path,
}, ";")

local uv = vim.uv or vim.loop

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

-- Structured-output mode (bench_history.sh): BENCH_JSON=1 suppresses the human
-- lines and emits one JSON object at the end — { label, bench, n, results } — so
-- a caller can aggregate many runs. BENCH_LABEL tags the run (a commit sha or
-- "working"). The scenario code is untouched; only how a result is REPORTED
-- changes, so the same pinned file measures every commit identically.
local JSON = (vim.env.BENCH_JSON or "") ~= ""
local LABEL = vim.env.BENCH_LABEL or ""
local RESULTS = {}
local function say(line)
	if not JSON then
		io.write(line)
	end
end
-- Record one measurement (and print it in human mode). A nil value + `error`
-- marks a scenario that raised — a commit whose API the pinned harness outran —
-- so the aggregate shows N/A for it instead of losing the whole run.
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
	record(name, "ms/op", per_op, { iters = iters })
	say(("%-52s %10.3f ms/op   (%d iters)\n"):format(name, per_op, iters))
end

---------------------------------------------------------------------------
-- Scenario trees
---------------------------------------------------------------------------

local LOREM = "the quick brown fox jumps over the lazy dog and packs boxes"

local function section(i)
	return {
		comp = ui.col,
		props = { style = { border = "single", padding = { x = 1 } } },
		children = {
			{ comp = ui.label, props = { text = "Section " .. i, style = { text_hl = "Title" } } },
			{
				comp = ui.row,
				props = { gap = 2 },
				children = {
					{ comp = ui.button, props = { label = "Run " .. i, on_press = function() end } },
					{ comp = ui.checkbox, props = { label = "opt " .. i, checked = i % 2 == 0 } },
				},
			},
			{ comp = ui.paragraph, props = { text = LOREM } },
		},
	}
end

-- App of `n` sections; `leaf_setter` (optional table) receives the use_state
-- setter of one extra leaf for the incremental-update scenario.
local function app_of(n, leaf_setter)
	return function(ctx, props)
		local _ = props and props.tick -- set_props forces the full re-render path
		local children = {}
		for i = 1, n do
			children[i] = section(i)
		end
		if leaf_setter then
			local s = ctx.use_state(0)
			leaf_setter.set = s.set
			children[#children + 1] = { comp = ui.label, props = { text = "count " .. s.get() } }
		end
		return { comp = ui.col, props = { gap = 1 }, children = children }
	end
end

local function fixed_host(w, h)
	return inline_host.new({
		get_size = function()
			return { width = w, height = h }
		end,
	})
end

---------------------------------------------------------------------------
-- Pure engine: layout + paint, no reconciler, no buffers
---------------------------------------------------------------------------

local function pure_tree(n)
	local children = {}
	for i = 1, n do
		children[i] = {
			kind = "col",
			props = { border = "single", padding = { x = 1 } },
			children = {
				{ kind = "text", props = { text_hl = "Title" }, text = "Section " .. i },
				{ kind = "text", props = { wrap = true }, text = LOREM },
			},
		}
	end
	return { kind = "col", props = { gap = 1 }, children = children }
end

local N = tonumber(vim.env.BENCH_N) or 100
say(("inline host benchmarks — N = %d sections (~%d nodes)\n\n"):format(N, N * 6))

bench("pure layout+paint (scroll mode)", 50, function()
	local tree = pure_tree(N)
	layout.compute(tree, { width = 60 })
	render.paint(tree, 60, tree.size.h)
end)

---------------------------------------------------------------------------
-- Reconciler + host: mount / full re-commit / incremental update
---------------------------------------------------------------------------

bench("mount (create_root + first commit + teardown)", 20, function()
	local host = fixed_host(60)
	local root = runtime.create_root(app_of(N), {}, { host = host })
	root:render()
	root:unmount()
end)

do
	local host = fixed_host(60)
	local root = runtime.create_root(app_of(N), { tick = 0 }, { host = host })
	root:render()
	bench("full re-commit (set_props, every component)", 50, function(i)
		root:set_props({ tick = i })
	end)
	root:unmount()
end

do
	local host = fixed_host(60)
	local setter = {}
	local root = runtime.create_root(app_of(N, setter), {}, { host = host })
	root:render()
	bench("incremental update (one leaf use_state)", 50, function(i)
		setter.set(i)
	end)
	root:unmount()
end

do
	-- The counter leaf is its own component: set() re-renders just that fiber,
	-- so everything measured here is the commit pipeline.
	local setter = {}
	local function Counter(ctx)
		local s = ctx.use_state(0)
		setter.set = s.set
		return { comp = ui.label, props = { text = "count " .. s.get() } }
	end
	local function App()
		local children = {}
		for i = 1, N do
			children[i] = section(i)
		end
		children[#children + 1] = { comp = Counter }
		return { comp = ui.col, props = { gap = 1 }, children = children }
	end
	local host = fixed_host(60)
	local root = runtime.create_root(App, {}, { host = host })
	root:render()
	bench("scoped leaf update (state in child component)", 50, function(i)
		setter.set(i)
	end)
	root:unmount()
end

---------------------------------------------------------------------------
-- Animation: CPU per wall-clock second of one live ui.animation in the page.
-- Async by nature (a uv timer drives it), so instead of ms/op this measures
-- os.clock() CPU over vim.wait(1000) and counts the buffer commits. The
-- moving frame is the bouncing-dot demo (dot crosses cells faster than the
-- tick rate, so ~every tick commits a one-row splice); the static frame
-- exercises the diff-skip (value() + deep_equal per tick, zero commits).
---------------------------------------------------------------------------

do
	local WIDTH = 30
	local function bouncing(progress)
		local t = progress < 0.5 and progress * 2 or 2 - progress * 2
		local pos = math.floor(t * (WIDTH - 1) + 0.5)
		return { string.rep(".", pos), { "o", hl = "Title" }, string.rep(".", WIDTH - 1 - pos) }
	end
	local function static()
		return { string.rep(".", WIDTH - 1), { "o", hl = "Title" } }
	end

	local function cpu_second(fn)
		collectgarbage("collect")
		local t0 = os.clock()
		vim.wait(1000, fn or function()
			return false
		end, 50)
		return (os.clock() - t0) * 1000
	end

	local function measure(label, value)
		local host = fixed_host(60)
		local function App()
			local children = {}
			for i = 1, N do
				children[i] = section(i)
			end
			children[#children + 1] = { comp = ui.animation, props = { duration = 1.3, value = value } }
			return { comp = ui.col, props = { gap = 1 }, children = children }
		end
		local root = runtime.create_root(App, {}, { host = host })
		root:render()
		local tick0 = vim.api.nvim_buf_get_changedtick(host.bufnr)
		local cpu = cpu_second()
		local commits = vim.api.nvim_buf_get_changedtick(host.bufnr) - tick0
		root:unmount()
		record(label, "ms CPU/s", cpu, { commits = commits })
		say(("%-52s %10.3f ms CPU/s (%d commits)\n"):format(label, cpu, commits))
	end

	local idle = cpu_second()
	record("idle event loop (animation baseline)", "ms CPU/s", idle)
	say(("%-52s %10.3f ms CPU/s\n"):format("idle event loop (animation baseline)", idle))
	measure("animation 30fps, moving frame (bouncing dot)", bouncing)
	measure("animation 30fps, static frame (diff-skipped)", static)
end

---------------------------------------------------------------------------
-- Scroll tick: WinScrolled → subwin resync only (no re-layout)
---------------------------------------------------------------------------

do
	local function App()
		local children = {}
		for i = 1, N do
			children[#children + 1] = { comp = ui.label, props = { text = "row " .. i } }
			if i % (math.floor(N / 4) + 1) == 0 then
				children[#children + 1] = { comp = ui.text_input, props = { style = { border = "single" } } }
			end
		end
		return { comp = ui.col, props = {}, children = children }
	end
	local handle = mount.floating(App, {}, { width = 40, height = 20, mode = "scroll" })
	local max_top = vim.api.nvim_buf_line_count(handle.bufnr) - 20
	bench("scroll tick (subwin resync via WinScrolled)", 200, function(i)
		local topline = (i * 7) % max_top + 1
		vim.api.nvim_win_call(handle.winid, function()
			vim.fn.winrestview({ topline = topline, lnum = topline })
		end)
		vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
	end)
	handle.unmount()
end

if JSON then
	io.write(vim.json.encode({ label = LABEL, bench = "run", n = N, results = RESULTS }) .. "\n")
else
	io.write("\ndone\n")
end
