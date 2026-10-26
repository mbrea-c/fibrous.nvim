-- Real TUI resize bursts. Timings cover geometry sync, reflow and :redraw,
-- not input delivery, terminal-emulator painting, or a settle-window timeout.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path
local termdraw = require("fibrous.bench.termdraw")
local n = tonumber(vim.env.BENCH_N) or 200
local frames = tonumber(vim.env.BENCH_FRAMES) or 12
local phase_file = vim.env.BENCH_PROFILE == "1" and dir .. "phase_profile.lua" or ""
local phases = phase_file ~= "" and dofile(phase_file) or nil
assert(frames >= 2, "resize_term requires at least two frames")
local results = {}
for _, kind in ipairs({ "markdown", "mixed", "clamped" }) do
  local receipt = vim.fn.tempname()
  local init = ([[
vim.o.termguicolors = true
local fixture = dofile(%q)
local kind, n, frames, receipt = %q, %d, %d, %q
local opts = { width = 100, height = 22, row = 0, col = 0, mode = "scroll" }
local app = require("fibrous.inline.mount").floating(fixture.scene(kind, n), {}, opts)
local phase_file = %q
local phases = phase_file ~= "" and dofile(phase_file) or nil
local profiler = phases and phases.standard()
local times, fingerprints, phase_frames = {}, {}, {}
local function redraw() vim.cmd("redraw") end
local function draw()
  app.relayout()
  if profiler then profiler:scope("redraw", redraw) else redraw() end
end
_G.FRAME = function(i)
  opts.width = fixture.widths[(i - 1) %% #fixture.widths + 1]
  if profiler then
    local report = profiler:measure(draw)
    phase_frames[#phase_frames + 1] = report
    times[#times + 1] = report.total_ms
  else
    local start = vim.uv.hrtime()
    draw()
    times[#times + 1] = (vim.uv.hrtime() - start) / 1e6
  end
  local marks = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(app.bufnr, -1, 0, -1, { details = true })) do
    local d = mark[4]
    if d.hl_group then marks[#marks + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group } end
  end
  table.sort(marks, function(a, b) return vim.json.encode(a) < vim.json.encode(b) end)
  fingerprints[#fingerprints + 1] = vim.fn.sha256(vim.json.encode({
    vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), marks }))
  if i == frames then
    table.sort(times)
    local report = { frames = i, p50 = times[math.ceil(#times * 0.50)],
      p95 = times[math.ceil(#times * 0.95)],
      fingerprint = vim.fn.sha256(table.concat(fingerprints)) }
    if phases then report.profile = phases.summarize(phase_frames) end
    vim.fn.writefile({ vim.json.encode(report) }, receipt)
  end
end
]]):format(dir .. "resize_fixture.lua", kind, n, frames, receipt, phase_file)
  local ok, result = pcall(termdraw.measure, { rtp = { cwd }, cols = 110, rows = 26,
    frames = frames, init = init, settle_ms = 1000, timeout_ms = 60000 })
  local completed = vim.fn.filereadable(receipt) == 1 and vim.json.decode(vim.fn.readfile(receipt)[1]) or nil
  vim.fn.delete(receipt)
  assert(ok, result)
  assert(completed and completed.frames == frames, "resize PTY loop incomplete for " .. kind .. "; refusing partial measurements")
  results[#results + 1] = { op = "redraw " .. kind, unit = "bytes/frame", value = result.per_frame,
    frames = frames, bytes = result.bytes, writes = result.writes,
    p50 = completed.p50, p95 = completed.p95, fingerprint = completed.fingerprint, profile = completed.profile }
end
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "resize_term", n = n, results = results }) .. "\n")
else
  for _, r in ipairs(results) do
    io.write(("%-24s %.3f bytes/frame  redraw p50 %.3f  p95 %.3f ms\n")
      :format(r.op, r.value, r.p50, r.p95))
    if r.profile then io.write(phases.format(r.profile) .. "\n") end
  end
end
