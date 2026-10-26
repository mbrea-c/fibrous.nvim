-- Markdown parse, warm resize, and annotation projection. Run with:
-- nix run .#bench-history -- --last 1 --reps 8 --benches markdown_workload
-- The harness comes from this file's directory; only the cwd library varies.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local rootdir = vim.fn.getcwd()
package.path = rootdir .. "/lua/?.lua;" .. rootdir .. "/lua/?/init.lua;" .. dir .. "?.lua;" .. package.path
local fixture = require("markdown_fixture")
local markdown = require("fibrous.markdown")
local runtime = require("fibrous.reactive.runtime")
local host_module = require("fibrous.inline.host")
local ui = require("fibrous.inline.components")
local Sources = require("fibrous.sources")
local Spans = require("fibrous.inline.spans")
local throughput = require("throughput")
local N = tonumber(vim.env.BENCH_N) or 200
local text, plain = fixture.document(N), fixture.plain(N)
local results = {}
local function bench(op, iters, fn, draw)
  fn()
  collectgarbage("collect")
  local start = vim.uv.hrtime()
  for _ = 1, iters do fn() end
  local r = { op = op, unit = "ms/op", value = (vim.uv.hrtime() - start) / iters / 1e6, iters = iters }
  if draw then
    local counted = throughput.counting(fn)
    r.cells, r.writes = counted.cells, counted.writes
  end
  results[#results + 1] = r
end

bench("parse plain (unmapped)", 15, function() markdown.parse(plain) end)
bench("parse mixed (unmapped)", 10, function() markdown.parse(text) end)
bench("parse mixed (mapped)", 10, function() markdown.parse(text, { source = true }) end)

do
  local list = {}
  for i = 1, 48 do list[i] = { ("word "):rep(3), hl = i % 2 == 0 and "Title" or "Comment" } end
  local flat, ranges = Spans.flatten(list)
  local pieces = { { s = 1, text = flat } }
  bench("attribute dense spans", 50, function()
    local runs = Spans.runs(pieces, ranges)
    assert(#runs == 48, "dense attribution lost a span")
  end)
end

for _, mapped in ipairs({ false, true }) do
  local width = 100
  local source = mapped and { id = "bench", text = text, data = { entry_id = "bench-entry" } } or nil
  local host = host_module.new({ get_size = function() return { width = width } end })
  local root = runtime.create_root(function()
    return { comp = ui.markdown, props = { text = text, source = source, source_entry = source } }
  end, {}, { host = host })
  root:render()
  bench("warm resize " .. (mapped and "(mapped)" or "(unmapped)"), 4, function()
    width = width == 100 and 64 or 100
    host.relayout()
    assert(host.tree.content.w == width, "resize did not take effect")
  end, true)
  if mapped then
    local ranges = fixture.ranges(text, math.min(N, 10))
    local function project(range)
      local locations = Sources.project("bench", range[1], range[2])
      assert(#locations == 1 and locations[1].bufnr == host.bufnr, "missing comment projection")
      local loc = locations[1]
      local shown = vim.api.nvim_buf_get_text(loc.bufnr, loc.row, loc.start_col, loc.row, loc.end_col, {})[1]
      assert(shown == text:sub(range[1] + 1, range[2]), "incorrect projected text")
    end
    bench("project one comment", 5, function() project(ranges[1]) end)
    bench("project ten comments", 2, function() for _, range in ipairs(ranges) do project(range) end end)
    bench("capture small selection", 5, function()
      local found = Sources.resolve(host.bufnr, { lnum = 1, end_lnum = 1, col = 1, end_col = 7 })
      assert(#found == 1 and found[1].quote == "Section", "incorrect selection capture")
    end)
    bench("locate whole entry", 10, function()
      assert(#Sources.entry_locations("bench-entry") == 1, "missing entry location")
    end)
  end
  root:unmount()
end

if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "markdown_workload", n = N, results = results }) .. "\n")
else
  for _, r in ipairs(results) do io.write(("%-38s %.3f %s\n"):format(r.op, r.value, r.unit)) end
end
