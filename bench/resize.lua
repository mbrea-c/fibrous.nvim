-- Warm reflow bursts, not parsing or component rerendering.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. dir .. "?.lua;" .. package.path
local fixture = require("resize_fixture")
local runtime = require("fibrous.reactive.runtime")
local Host = require("fibrous.inline.host")
local throughput = require("throughput")
local n = tonumber(vim.env.BENCH_N) or 200
local results = {}
local function percentile(values, p)
  table.sort(values)
  return values[math.max(1, math.ceil(#values * p))]
end
for _, kind in ipairs({ "markdown", "mixed", "clamped", "height" }) do
  local size = { width = 100, height = kind == "height" and 24 or nil }
  local host = Host.new({ get_size = function() return size end })
  local root = runtime.create_root(fixture.scene(kind == "height" and "mixed" or kind, n), {}, { host = host })
  root:render()
  local function frame(i)
    if kind == "height" then size.height = i % 2 == 0 and 24 or 30
    else size.width = fixture.widths[(i - 1) % #fixture.widths + 1] end
    host.relayout()
  end
  for i = 1, #fixture.widths do frame(i) end
  collectgarbage("collect")
  local times, cpu = {}, os.clock()
  for i = 1, #fixture.widths * 2 do
    local start = vim.uv.hrtime()
    frame(i)
    times[#times + 1] = (vim.uv.hrtime() - start) / 1e6
  end
  local cpu_ms = (os.clock() - cpu) / #times * 1000
  local sum = 0
  for _, ms in ipairs(times) do sum = sum + ms end
  local counted = throughput.counting(function() frame(7) end)
  local fingerprint = fixture.fingerprint(host)
  results[#results + 1] = { op = "reflow " .. kind, unit = "ms/frame", value = sum / #times,
    p50 = percentile(times, 0.50), p95 = percentile(times, 0.95), cpu_ms = cpu_ms,
    frames = #times, cells = counted.cells, writes = counted.writes, fingerprint = fingerprint }
  root:unmount()
end
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "resize", n = n, results = results }) .. "\n")
else
  for _, r in ipairs(results) do
    io.write(("%-24s mean %.3f  p50 %.3f  p95 %.3f  CPU %.3f ms/frame  cells %d\n")
      :format(r.op, r.value, r.p50, r.p95, r.cpu_ms, r.cells))
  end
end
