-- First width change after a fresh mount, before any resize warm-up.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. dir .. "?.lua;" .. package.path
local fixture = require("resize_fixture")
local runtime, Host = require("fibrous.reactive.runtime"), require("fibrous.inline.host")
local n = tonumber(vim.env.BENCH_N) or 200
local results = {}
local function percentile(values, p)
  table.sort(values)
  return values[math.ceil(#values * p)]
end
for _, kind in ipairs({ "markdown", "mixed", "clamped" }) do
  local times = {}
  for _ = 1, 8 do
    local size = { width = 100 }
    local host = Host.new({ get_size = function() return size end })
    local root = runtime.create_root(fixture.scene(kind, n), {}, { host = host })
    root:render()
    collectgarbage("collect")
    size.width = 64
    local start = vim.uv.hrtime()
    host.relayout()
    times[#times + 1] = (vim.uv.hrtime() - start) / 1e6
    assert(host.tree.content.w == 64)
    root:unmount()
  end
  local sum = 0
  for _, ms in ipairs(times) do sum = sum + ms end
  results[#results + 1] = { op = "first resize " .. kind, unit = "ms/op", value = sum / #times,
    p50 = percentile(times, 0.5), p95 = percentile(times, 0.95), iters = #times }
end
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "resize_first", n = n, results = results }) .. "\n")
else
  for _, r in ipairs(results) do
    io.write(("%-24s mean %.3f  p50 %.3f  p95 %.3f ms\n"):format(r.op, r.value, r.p50, r.p95))
  end
end
