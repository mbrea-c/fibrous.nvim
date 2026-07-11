-- Markdown benchmark: the cost of turning markdown source into fibrous vnodes,
-- split into its stages so a regression points at the culprit (parser, renderer,
-- or the mount/commit). The widget caches the AST per source, so the numbers to
-- watch in a streaming chat are "parse" (paid once on settle) and "render"
-- (paid on every relayout from the cached AST). Invoked as:
--   make bench-markdown            # default N=200 sections
--   make bench-markdown BENCH_N=800

-- Two axes, kept separate so cross-history trends stay honest (see the note in
-- bench/transcript.lua): the LIBRARY comes from the cwd, the HARNESS from here.
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
local ui = require("fibrous.inline.components")
local markdown = require("fibrous.markdown")
local doc_render = require("fibrous.doc.render")
local throughput = require("throughput")

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
	local ok, err = pcall(fn, 0)
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
	say(("%-52s %10.3f ms/op  (%d iters)\n"):format(name, per_op, iters))
end

local WIDTH = 100
local N = tonumber(vim.env.BENCH_N) or 200

-- One realistic section: a heading, a paragraph with mixed inline (bold, emph,
-- code, a link), a list with a task item, a blockquote, and a fenced code block.
local SECTION = table.concat({
	"## Section %d",
	"",
	"Some **bold** and *emphasis* with `inline code` and a [link](http://example.com/%d) inline.",
	"",
	"- first point",
	"- second point with `code`",
	"- [x] a finished task",
	"",
	"> a short blockquote about section %d and its details",
	"",
	"```lua",
	"local x = %d",
	"return x + 1",
	"```",
	"",
}, "\n")

local function big_doc(n)
	local parts = {}
	for i = 1, n do
		parts[i] = SECTION:format(i, i, i, i)
	end
	return table.concat(parts, "\n")
end

local SRC = big_doc(N)

say(("markdown benchmarks — N = %d sections\n\n"):format(N))

-- The parser alone: source → document AST (the parse-on-settle cost).
bench("parse (source → AST)", 20, function()
	markdown.parse(SRC)
end)

-- The renderer alone, from a cached AST → fibrous vnodes (paid every relayout).
do
	local doc = markdown.parse(SRC)
	bench("render (cached AST → vnodes)", 20, function()
		doc_render.render(doc, {})
	end)
end

-- The full pipeline with no cache: source → AST → vnodes.
bench("parse + render (source → vnodes)", 20, function()
	doc_render.render(markdown.parse(SRC), {})
end)

-- Mount the real widget: create_root + first commit (layout + paint + write) +
-- teardown, the cost a page pays to show a large markdown document once.
do
	local function md_host()
		return inline_host.new({
			get_size = function()
				return { width = WIDTH }
			end,
		})
	end
	bench("mount ui.markdown (create_root + commit + teardown)", 5, function()
		local host = md_host()
		local root = runtime.create_root(function()
			return { comp = ui.markdown, props = { text = SRC } }
		end, {}, { host = host })
		root:render()
		root:unmount()
	end)
end

-- Math rendering, single-line and stacked. A FRESH equation per op defeats the
-- module cache, so these are the cold-render costs (production pays them once
-- per unique equation, then the cache serves relayouts for free).
do
	local mathr = require("fibrous.doc.math")
	bench("math single-line (fresh eq/op)", 500, function(i)
		mathr.single(("\\frac{%d}{x_%d + 1} = \\sqrt{a^2 + b^2}"):format(i, i))
	end)
	bench("math stacked/display (fresh eq/op)", 500, function(i)
		mathr.stack(("x = \\frac{-%d \\pm \\sqrt{b^2 - 4ac}}{2a_%d}"):format(i, i))
	end)
end

if JSON then
	io.write(vim.json.encode({ label = LABEL, bench = "markdown", n = N, results = RESULTS }) .. "\n")
else
	io.write("\ndone\n")
end
