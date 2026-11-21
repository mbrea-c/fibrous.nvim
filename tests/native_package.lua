-- Isolated installed-package smoke test, deliberately not tests/run.lua.
local path = assert(vim.env.FIBROUS_PACKAGE)
vim.opt.runtimepath:prepend(path)
local fibrous = require("fibrous")
local native = vim.env.EXPECT_NATIVE == "1"
assert(require("fibrous.config").native_markdown == native, "incorrect package default")
local size = { width = 40 }
local host = require("fibrous.inline.host").new({
  get_size = function()
    return size
  end,
})
local root = require("fibrous.reactive.runtime").create_root(
  fibrous.ui.markdown,
  { text = "package **smoke** test" },
  { host = host }
)
root:render()
size.width = 20
host.relayout()
assert((host.markdown_backend == "rust") == native, host.markdown_fallback or "incorrect renderer")
assert(vim.trim(host.canvas_lines[1]) == "package smoke test")
root:unmount()
print("installed package: " .. (native and "rust" or "lua"))
