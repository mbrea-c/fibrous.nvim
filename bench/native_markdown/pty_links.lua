-- A real TUI event loop receives queued mouse press/release input in screen coordinates.
local receipt = vim.fn.tempname()
local done
local child = vim.fn.jobstart({
  vim.v.progpath, "-u", "NONE", "-i", "NONE", "-n", "-c", "luafile bench/native_markdown/features.lua",
}, {
  pty = true, width = 110, height = 26,
  env = {BENCH_POINTER_RECEIPT = receipt, TERM = "xterm-256color"},
  on_exit = function(_, code) done = code end,
})
assert(child > 0)
if not vim.wait(25000, function() return done ~= nil end, 10) then
  vim.fn.jobstop(child)
  error("PTY mouse sequence timed out")
end
local lines = vim.fn.filereadable(receipt) == 1 and vim.fn.readfile(receipt) or {}
vim.fn.delete(receipt)
assert(done == 0 and #lines == 1, lines[1] or "missing PTY mouse receipt")
local result = vim.json.decode(lines[1])
assert(#result.frames == 5, "incomplete PTY mouse sequence")
io.write(lines[1] .. "\n")
