-- Terminal-draw benchmark harness — the "one layer down" measurement, and the
-- honest companion to the buffer-write cells/op metric (bench/throughput.lua).
--
-- cells/op counts what fibrous writes to the BUFFER. This counts what nvim's TUI
-- then pushes at the TERMINAL: the bytes written to a real pty per redraw. That
-- is the number that governs tmux+ssh stability, because it is literally what
-- goes over the wire — and it captures two things the buffer metric cannot:
--   * highlight-only redraws. nvim_set_hl writes zero buffer chars, but the TUI
--     repaints every cell using the group (~hundreds of bytes per flip). At the
--     ext_linegrid UI layer this is a tiny hl_attr_define with no grid_line
--     cells, so even "count grid_line cells" would miss it — only the pty sees
--     the real repaint. (This is exactly the water-indicator flicker.)
--   * escape-sequence overhead — cursor moves, SGR colour changes, scroll
--     regions — the per-frame cost that has nothing to do with content size.
--
-- How: spawn a child nvim in a pty (a real TUI — headless/--embed emit no
-- terminal output), attach a scenario, force N redraws, and sum the pty bytes.
-- The child is `--clean` (no user config); pass `rtp` dirs to make the library
-- under test requirable, and an `init` chunk that defines a global `FRAME(i)`.
--
-- EXPOSED under lua/ (not bench/) on purpose: downstream apps (weave) put
-- fibrous on their package.path, so they can `require("fibrous.bench.termdraw")`
-- and measure their OWN screens on the same harness.

local uv = vim.uv or vim.loop

local M = {}

-- Exact byte length of one jobstart stdout event. The channel splits the raw
-- stream on \n (and stores NUL as \n); concatenating the pieces back with \n
-- reconstructs the original byte count exactly — no line spans an event
-- boundary with a separator, so nothing is double-counted.
local function event_bytes(data)
	return #table.concat(data, "\n")
end

---@class TermDrawOpts
---@field init string         Lua chunk run in the child (`:luafile`d); must set global FRAME(i)
---@field frames? integer     forced redraws to measure (default 60)
---@field cols? integer       pty width (default 80)
---@field rows? integer       pty height (default 24)
---@field rtp? string[]       dirs prepended to the child's runtimepath (so require finds the lib)
---@field settle_ms? integer  quiescence window that marks "the draw finished" (default 120)
---@field timeout_ms? integer max wait for a settle (default 5000)

---@class TermDrawResult
---@field bytes integer      terminal bytes written across the measured frames
---@field writes integer     pty write bursts (a proxy for redraw-cycle count / latency sensitivity)
---@field frames integer     frames measured
---@field per_frame number   bytes / frames — the per-redraw terminal cost
---@field ms number          wall-clock the measured loop took

-- Spawn the child nvim in a pty and return a small driver over it: the shared
-- machinery behind both measure() (a forced FRAME loop) and drive() (an app
-- running on its OWN event loop). The counters live in a table the on_stdout
-- callback mutates; `last` is the timestamp of the most recent byte burst, so a
-- caller can wait for quiescence. The child is `--clean` with the usual chrome
-- silenced, and `opts.init` (a Lua chunk defining the scene) is written to a
-- temp file the caller :luafiles.
---@param opts TermDrawOpts
local function spawn_pty(opts)
	local cols = opts.cols or 80
	local rows = opts.rows or 24
	local settle = opts.settle_ms or 120
	local timeout = opts.timeout_ms or 5000

	local init_path = vim.fn.tempname() .. ".lua"
	do
		local fh = assert(io.open(init_path, "w"))
		fh:write(opts.init or "_G.FRAME = function() end\n")
		fh:close()
	end

	local c = { total = 0, writes = 0, last = uv.now() }
	-- --clean isolates from user config; the extra chrome is silenced so the pty
	-- carries the app's draw, not a statusline/ruler/command-echo redrawing.
	local args = {
		vim.v.progpath,
		"--clean",
		"-n",
		"--cmd",
		"set noshowcmd noshowmode noruler laststatus=0 nomore",
	}
	for _, dir in ipairs(opts.rtp or {}) do
		args[#args + 1] = "--cmd"
		args[#args + 1] = "set rtp^=" .. dir
	end

	local chan = vim.fn.jobstart(args, {
		pty = true,
		width = cols,
		height = rows,
		on_stdout = function(_, data)
			c.total = c.total + event_bytes(data)
			c.writes = c.writes + 1
			c.last = uv.now()
		end,
	})
	assert(chan > 0, "termdraw: failed to spawn child nvim")

	-- Wait for the child to go quiet. `last` is reset right before a send so the
	-- window covers the burst that send triggers (the reply arrives a few ms
	-- later, well inside `settle`, and each burst pushes the deadline out until
	-- the redraws are truly done).
	local function settle_wait()
		vim.wait(timeout, function()
			return uv.now() - c.last > settle
		end, 10)
	end
	-- Send raw bytes to the child and wait for its redraws to settle.
	local function send(str)
		c.last = uv.now()
		vim.fn.chansend(chan, str)
		settle_wait()
	end
	-- Hold the measuring loop for `ms` of WALL CLOCK, counting every byte the
	-- child draws meanwhile — for an app redrawing off its own timers (streaming,
	-- animation), where there is no single settle point to wait for.
	local function hold(ms)
		vim.wait(ms, function()
			return false
		end, 10)
	end

	return {
		chan = chan,
		counters = c,
		settle_wait = settle_wait,
		send = send,
		hold = hold,
		luafile = function()
			send((":luafile %s\r"):format(init_path))
		end,
		stop = function()
			vim.fn.jobstop(chan)
			os.remove(init_path)
		end,
	}
end

-- Measure the terminal draw a scenario produces. Returns a TermDrawResult.
---@param opts TermDrawOpts
---@return TermDrawResult
function M.measure(opts)
	opts = opts or {}
	local frames = opts.frames or 60

	local child = spawn_pty(opts)
	local c = child.counters
	child.settle_wait() -- the startup paint
	child.luafile() -- the scenario mounted

	local b0, w0 = c.total, c.writes
	local t0 = uv.now()
	-- One Ex command (its ~40-byte echo is a one-off, dwarfed by the frames), an
	-- explicit :redraw per iteration so each frame flushes to the pty separately
	-- rather than coalescing into a single final paint.
	child.send((":lua for i=1,%d do FRAME(i) vim.cmd('redraw') end\r"):format(frames))
	local ms = uv.now() - t0

	child.stop()

	local bytes = c.total - b0
	return {
		bytes = bytes,
		writes = c.writes - w0,
		frames = frames,
		per_frame = bytes / frames,
		ms = ms,
	}
end

---@class TermDriveStep
---@field label? string   name shown in the per-step result
---@field lua? string     a Lua chunk run in the child (wrapped as `:lua <chunk>\r`) before the wait
---@field send? string    raw bytes to chansend before the wait (append your own \r); use for keystrokes
---@field wait_ms integer wall-clock window to hold and count the child's self-driven draws over

---@class TermDriveStepResult
---@field label? string
---@field bytes integer   terminal bytes drawn during this step's window
---@field writes integer  pty write bursts during the window

---@class TermDriveOpts : TermDrawOpts
---@field steps TermDriveStep[]  the timed sequence to drive; the scene runs on its OWN event loop

---@class TermDriveResult
---@field bytes integer               total terminal bytes across all steps
---@field writes integer              total pty write bursts
---@field ms number                   wall-clock the driven sequence took
---@field per_ms number               bytes per millisecond (the sustained draw rate)
---@field steps TermDriveStepResult[] per-step byte counts

-- Drive an app that redraws off its OWN event loop (async streaming, uv-timer
-- animation) and measure the terminal bytes over each timed window. Unlike
-- measure(), it never forces `:redraw`: the scene paints itself, and each step
-- holds wall-clock time counting whatever it draws. `steps` optionally chansend
-- a Lua chunk or keys first (e.g. submit a prompt), then hold. Attribution is by
-- window, so size the waits to the app's timeline (one turn per step).
---@param opts TermDriveOpts
---@return TermDriveResult
function M.drive(opts)
	opts = opts or {}
	local child = spawn_pty(opts)
	local c = child.counters
	child.settle_wait() -- the startup paint
	child.luafile() -- mount the scene (and start its timers)
	child.settle_wait()

	local start_b, start_w = c.total, c.writes
	local t0 = uv.now()
	local steps = {}
	for _, step in ipairs(opts.steps or {}) do
		local b0, w0 = c.total, c.writes
		local payload = step.send or (step.lua and (":lua " .. step.lua .. "\r"))
		if payload then
			c.last = uv.now()
			vim.fn.chansend(child.chan, payload)
		end
		child.hold(step.wait_ms or 1000)
		steps[#steps + 1] = {
			label = step.label,
			bytes = c.total - b0,
			writes = c.writes - w0,
		}
	end
	local ms = uv.now() - t0

	child.stop()

	local bytes = c.total - start_b
	return {
		bytes = bytes,
		writes = c.writes - start_w,
		ms = ms,
		per_ms = bytes / math.max(ms, 1),
		steps = steps,
	}
end

return M
