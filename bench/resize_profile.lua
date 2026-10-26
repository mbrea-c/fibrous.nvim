-- Diagnostic companion to resize.lua. It changes no production rendering code.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. dir .. "?.lua;" .. package.path
local fixture = require("resize_fixture")
local phases = require("phase_profile")
local runtime, Host = require("fibrous.reactive.runtime"), require("fibrous.inline.host")
local throughput = require("throughput")
local n = tonumber(vim.env.BENCH_N) or 200
local order = vim.env.BENCH_PROFILE_ORDER or "plain-first"
assert(order == "plain-first" or order == "profiled-first", "invalid BENCH_PROFILE_ORDER")
local results = {}

local function run(kind, enabled)
  local size = { width = 100, height = kind == "height" and 24 or nil }
  local host = Host.new({ get_size = function() return size end })
  local root = runtime.create_root(fixture.scene(kind == "height" and "mixed" or kind, n), {}, { host = host })
  local p = enabled and phases.standard() or nil
  local function frame(i)
    if kind == "height" then size.height = i % 2 == 0 and 24 or 30
    else size.width = fixture.widths[(i - 1) % #fixture.widths + 1] end
    host.relayout()
  end
  local ok, out = pcall(function()
    root:render()
    for i = 1, #fixture.widths do frame(i) end
    collectgarbage("collect")
    local frames = {}
    for i = 1, #fixture.widths * 2 do
      if p then frames[i] = p:measure(frame, i)
      else
        local start = vim.uv.hrtime()
        frame(i)
        local ms = (vim.uv.hrtime() - start) / 1e6
        frames[i] = { total_ms = ms, phases_ms = { other = ms }, calls = {} }
      end
    end
    local counted = throughput.counting(function() frame(7) end)
    return { summary = phases.summarize(frames), fingerprint = fixture.fingerprint(host),
      cells = counted.cells, writes = counted.writes }
  end)
  root:unmount()
  if not ok then error(out, 0) end
  return out
end

for _, kind in ipairs({ "markdown", "mixed", "clamped", "height" }) do
  local plain, profiled
  if order == "profiled-first" then profiled, plain = run(kind, true), run(kind, false)
  else plain, profiled = run(kind, false), run(kind, true) end
  assert(plain.fingerprint == profiled.fingerprint and plain.cells == profiled.cells
    and plain.writes == profiled.writes, "profiling changed rendered output for " .. kind)
  local summary = profiled.summary
  summary.slowest.width = kind == "height" and 100
    or fixture.widths[(summary.slowest.index - 1) % #fixture.widths + 1]
  results[#results + 1] = { op = "phased reflow " .. kind, unit = "ms/frame", value = summary.mean_ms,
    p50 = summary.p50_ms, p95 = summary.p95_ms, frames = #fixture.widths * 2,
    profile = summary, unprofiled = { mean_ms = plain.summary.mean_ms,
      p50_ms = plain.summary.p50_ms, p95_ms = plain.summary.p95_ms },
    overhead_ms = summary.mean_ms - plain.summary.mean_ms,
    fingerprint = profiled.fingerprint, cells = profiled.cells, writes = profiled.writes, output_matches = true }
end
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "resize_profile",
    n = n, order = order, results = results }) .. "\n")
else
  io.write("Exclusive instrumented wall time; overhead delta includes run-to-run noise.\n")
  for _, r in ipairs(results) do
    io.write(("%s: unprofiled %.3f ms, instrumented %.3f ms, delta %+.3f ms\n")
      :format(r.op, r.unprofiled.mean_ms, r.value, r.overhead_ms))
    io.write(phases.format(r.profile) .. "\n")
  end
end
