-- Real terminal draw cost for Markdown reflow, with and without annotations.
-- Receipt checks prevent slow frames from being mistaken for completed frames.
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local rootdir = vim.fn.getcwd()
package.path = rootdir .. "/lua/?.lua;" .. rootdir .. "/lua/?/init.lua;" .. package.path
local termdraw = require("fibrous.bench.termdraw")
local N = tonumber(vim.env.BENCH_N) or 200
local frames = tonumber(vim.env.BENCH_FRAMES) or 12
local results = {}
for _, kind in ipairs({ "plain", "mapped", "comments" }) do
  local receipt = vim.fn.tempname()
  local init = ([[
vim.o.termguicolors = true
local fixture = dofile(%q)
local ui = require("fibrous.inline.components")
local Sources = require("fibrous.sources")
local text = fixture.document(%d)
local kind, frames, receipt = %q, %d, %q
local source = kind ~= "plain" and { id = "bench", text = text, data = { entry_id = "bench-entry" } } or nil
local opts = { width = 100, height = 22, row = 0, col = 0, mode = "scroll" }
local app = require("fibrous.inline.mount").floating(function()
  return { comp = ui.markdown, props = { text = text, source = source, source_entry = source } }
end, {}, opts)
local ns = vim.api.nvim_create_namespace("MarkdownBenchComments")
vim.api.nvim_set_hl(0, "MarkdownBenchComment", { bg = "#334455" })
local ranges = fixture.ranges(text, math.min(3, %d))
local fingerprints = {}
_G.FRAME = function(i)
  opts.width = i %% 2 == 1 and 64 or 100
  app.relayout()
  local positions = {}
  if kind == "comments" then
    vim.api.nvim_buf_clear_namespace(app.bufnr, ns, 0, -1)
    for _, range in ipairs(ranges) do
      local locations = Sources.project("bench", range[1], range[2])
      assert(#locations == 1, "lost comment during resize")
      for _, loc in ipairs(locations) do
        vim.api.nvim_buf_set_extmark(loc.bufnr, ns, loc.row, loc.start_col, {
          end_row = loc.row, end_col = loc.end_col, hl_group = "MarkdownBenchComment" })
        positions[#positions + 1] = { loc.row, loc.start_col, loc.end_col }
      end
    end
  end
  local content = table.concat(vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false), "\n")
  fingerprints[#fingerprints + 1] = vim.fn.sha256(content .. vim.json.encode(positions))
  if i == frames then vim.fn.writefile({ vim.json.encode({ frames = i, fingerprint = vim.fn.sha256(table.concat(fingerprints)) }) }, receipt) end
end
]]):format(dir .. "markdown_fixture.lua", N, kind, frames, receipt, N)
  local ok, r = pcall(termdraw.measure, { rtp = { rootdir }, cols = 110, rows = 26,
    frames = frames, init = init, settle_ms = 1000, timeout_ms = 60000 })
  local completed = vim.fn.filereadable(receipt) == 1 and vim.json.decode(vim.fn.readfile(receipt)[1]) or nil
  vim.fn.delete(receipt)
  assert(ok, r)
  assert(completed and completed.frames == frames, "PTY workload did not finish; refusing partial throughput")
  results[#results + 1] = { op = "resize " .. kind, unit = "bytes/frame", value = r.per_frame,
    bytes = r.bytes, frames = frames, writes = r.writes, fingerprint = completed.fingerprint }
end
if (vim.env.BENCH_JSON or "") ~= "" then
  io.write(vim.json.encode({ label = vim.env.BENCH_LABEL or "", bench = "markdown_term", n = N, results = results }) .. "\n")
else
  for _, r in ipairs(results) do io.write(("%-24s %.3f bytes/frame  fingerprint=%s\n"):format(r.op, r.value, r.fingerprint)) end
end
