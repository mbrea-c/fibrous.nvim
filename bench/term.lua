-- Terminal-draw benchmark — the "one layer down" companion to bench/run.lua.
-- Where run.lua's cells/op counts what fibrous writes to the BUFFER, this counts
-- what nvim's TUI then pushes at the TERMINAL (bytes to a real pty per redraw) —
-- the number that governs tmux+ssh stability, highlight repaints and escape
-- overhead included. Invoked as:
--   make bench-term      (nvim --headless -u NONE -i NONE -l bench/term.lua)
--
-- Each scenario mounts a fibrous app in a child nvim TUI and drives one mutation
-- per frame; the harness (fibrous.bench.termdraw) sums the terminal bytes.
--
-- Same structured-output contract as the other benches: BENCH_JSON=1 emits one
-- { label, bench, n, results } object; BENCH_LABEL tags it.

local root_dir = vim.fn.getcwd()
package.path = table.concat({
	root_dir .. "/lua/?.lua",
	root_dir .. "/lua/?/init.lua",
	package.path,
}, ";")

local termdraw = require("fibrous.bench.termdraw")

local JSON = (vim.env.BENCH_JSON or "") ~= ""
local LABEL = vim.env.BENCH_LABEL or ""
local RESULTS = {}
local function say(line)
	if not JSON then
		io.write(line)
	end
end

local COLS = tonumber(vim.env.BENCH_COLS) or 80
local ROWS = tonumber(vim.env.BENCH_ROWS) or 24
local FRAMES = tonumber(vim.env.BENCH_FRAMES) or 60

say(("terminal-draw benchmarks — %dx%d pty, %d frames each\n\n"):format(COLS, ROWS, FRAMES))

-- Run one scenario: `init` mounts a fibrous app in the child and defines a global
-- FRAME(i) that performs one frame's mutation. `value` = bytes/frame (the ssh cost).
local function run(name, init)
	local ok, r = pcall(termdraw.measure, {
		rtp = { root_dir },
		cols = COLS,
		rows = ROWS,
		frames = FRAMES,
		init = init,
	})
	if not ok then
		RESULTS[#RESULTS + 1] = { op = name, unit = "bytes/frame", value = nil, error = tostring(r) }
		say(("%-40s ERROR: %s\n"):format(name, tostring(r)))
		return
	end
	RESULTS[#RESULTS + 1] =
		{ op = name, unit = "bytes/frame", value = r.per_frame, bytes = r.bytes, writes = r.writes, frames = r.frames }
	say(
		("%-40s %8.1f bytes/frame  (%d bytes, %d writes, %d frames)\n"):format(
			name,
			r.per_frame,
			r.bytes,
			r.writes,
			r.frames
		)
	)
end

-- A common preamble the scenarios share: page of filler + a mount helper.
local PRE = [[
  local mount = require("fibrous.inline.mount")
  local ui = require("fibrous.inline.components")
]]

-- One small leaf changes per frame (the common interactive path): the splice
-- writes one line, and this is what that costs on the wire.
run(
	"incremental update (one leaf)",
	PRE
		.. [[
  local set
  local function Counter(ctx) local s = ctx.use_state(0); set = s.set
    return { comp = ui.label, props = { text = "count " .. s.get() } } end
  local function App()
    local kids = {}
    for i = 1, 8 do kids[i] = { comp = ui.label, props = { text = ("row %d — the quick brown fox"):format(i) } } end
    kids[#kids+1] = { comp = Counter }
    return { comp = ui.col, props = { gap = 1 }, children = kids }
  end
  mount.floating(App, {}, { width = 50, height = 20 })
  _G.FRAME = function(i) set(i) end
]]
)

-- An animation moving a dot across a full-width row every frame — the water /
-- spinner shape. The whole row redraws each frame.
run(
	"animation frame (moving dot, full row)",
	PRE
		.. [[
  local W = 48
  local set
  local function Dot(ctx) local s = ctx.use_state(0); set = s.set
    local pos = s.get() % W
    return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
  local function App() return { comp = ui.col, props = {}, children = { { comp = Dot } } } end
  mount.floating(App, {}, { width = W + 2, height = 3 })
  _G.FRAME = function(i) set(i) end
]]
)

-- A highlight-only churn: NOTHING is written to the buffer, only a group's
-- colour flips (the water's apply_colors shape). The buffer cells/op metric sees
-- zero here; the terminal repaints the tagged row every frame — this is the
-- flicker cost, and only this layer shows it.
run(
	"highlight churn (colour flip, no buffer write)",
	PRE
		.. [[
  local function App() return { comp = ui.col, props = {}, children = {
    { comp = ui.label, props = { text = ("X"):rep(48), style = { text_hl = "FibrousBenchGrp" } } } } } end
  mount.floating(App, {}, { width = 50, height = 3 })
  _G.FRAME = function(i)
    vim.api.nvim_set_hl(0, "FibrousBenchGrp", { fg = i % 2 == 0 and "#00ff00" or "#ff2020" })
  end
]]
)

-- A still container float under an animating sibling: the dot moves every frame
-- (flushing the root), but the 30-row container is untouched. Its float must NOT
-- redraw per frame — this should track close to "animation frame" above, NOT
-- add a full float repaint on top (the reposition-idempotence win; guarded in
-- tests/bench/termdraw_spec.lua).
run(
	"still container float under animation",
	PRE
		.. [[
  local function rows(n)
    local k = {}
    for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
    return k
  end
  local W = 40
  local set
  local function Dot(ctx) local s = ctx.use_state(0); set = s.set
    local pos = s.get() % W
    return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
  local function App() return { comp = ui.col, props = {}, children = {
    { comp = Dot },
    { comp = ui.container, props = { height = 14, scroll_x = false }, children = rows(30) },
  } } end
  mount.floating(App, {}, { width = 50, height = 20 })
  _G.FRAME = function(i) set(i) end
]]
)

-- A FOCUSED root under an animating sibling, cursor parked on a static row: the
-- dot moves every frame (flushing the root), and because the root is the live
-- pointer the cursor anchor runs to hold the parked entry. If that entry hasn't
-- MOVED the anchor must write NO view — a winrestview invalidates the window and
-- repaints the whole float, the ssh+tmux flicker that returned only with the
-- ROOT focused. This must track close to "animation frame", NOT add a full-float
-- repaint per frame (the reanchor-idempotence win; guarded in
-- tests/bench/termdraw_spec.lua).
run(
	"focused root, cursor anchored under animation",
	PRE
		.. [[
  local function rows(n)
    local k = {}
    for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
    return k
  end
  local W = 40
  local set
  local function Dot(ctx) local s = ctx.use_state(0); set = s.set
    local pos = s.get() % W
    return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
  local function App() return { comp = ui.col, props = {}, children =
    vim.list_extend({ { comp = Dot } }, rows(30)) } end
  local handle = mount.floating(App, {}, { width = 50, height = 16, mode = "scroll" })
  handle.focus()
  -- park the cursor on a static entry so the anchor pins it; the dot above
  -- animates every frame, flushing the root but never moving row 12
  vim.api.nvim_win_set_cursor(handle.winid, { 12, 0 })
  _G.FRAME = function(i) set(i) end
]]
)

-- An UNFOCUSED scroll surface holding its view under an animating leaf inside
-- it: the dot moves every frame, but the surface pins its topline WITHOUT a
-- winrestview per frame (the unfocused-anchor idempotence win; guarded in
-- tests/bench/termdraw_spec.lua). Tracks close to "animation frame".
run(
	"unfocused surface holds view under animation",
	PRE
		.. [[
  local function rows(n)
    local k = {}
    for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
    return k
  end
  local W = 40
  local set
  local function Dot(ctx) local s = ctx.use_state(0); set = s.set
    local pos = s.get() % W
    return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
  local function App() return { comp = ui.col, props = {}, children =
    vim.list_extend(rows(30), { { comp = Dot } }) } end
  -- mounted UNFOCUSED (never focused), scrolled so a static row tops the view
  local handle = mount.floating(App, {}, { width = 50, height = 8, mode = "scroll" })
  vim.api.nvim_win_call(handle.winid, function() vim.fn.winrestview({ topline = 24 }) end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
  _G.FRAME = function(i) set(i) end
]]
)

if JSON then
	io.write(vim.json.encode({ label = LABEL, bench = "term", n = FRAMES, results = RESULTS }) .. "\n")
else
	io.write("\ndone\n")
end
