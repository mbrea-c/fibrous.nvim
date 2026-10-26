-- Transient allocation and CPU cost of the private parser provenance maps.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local rootdir = vim.fn.getcwd()
package.path = rootdir .. "/lua/?.lua;" .. rootdir .. "/lua/?/init.lua;" .. dir .. "?.lua;" .. package.path
local fixture = require("markdown_fixture")
local Markdown = require("fibrous.markdown")
local Source = require("fibrous.doc.source")
local N = tonumber(vim.env.BENCH_N) or 200
local text, plain = fixture.document(N), ("x"):rep(N * 256)
local results = {}
local function bench(name, fn)
  for _ = 1, 3 do fn() end
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  local t = vim.uv.hrtime()
  local held = {}
  for i = 1, 5 do held[i] = fn() end
  local elapsed = (vim.uv.hrtime() - t) / 5 / 1e6
  local allocated = (collectgarbage("count") - before) / 5
  collectgarbage("restart")
  assert(#held == 5)
  results[#results + 1] = { op = name .. " allocation", unit = "KiB/op", value = allocated, iters = 5 }
  results[#results + 1] = { op = name .. " CPU (GC stopped)", unit = "ms/op", value = elapsed, iters = 5 }
end
bench("identity and slices", function()
  local map = Source.identity(plain, 100)
  local first = Source.slice(map, 3, #plain - 2)
  local second = Source.slice(first, 3, #plain - 6)
  assert(second[1] == 104)
  return { map, first, second }
end)
bench("mapped parse", function() return Markdown.parse(text, { source = true }) end)
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "markdown_maps", n = N, results = results }) .. "\n")
else
  for _, r in ipairs(results) do io.write(("%-42s %.3f %s\n"):format(r.op, r.value, r.unit)) end
end
