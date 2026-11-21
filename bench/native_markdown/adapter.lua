-- Benchmark the same adapter shipped by the optional native package.
local adapter = require("fibrous.markdown.native_adapter")
local lib = assert(package.loadlib(assert(vim.env.FIBROUS_BENCH_MARKDOWN), "luaopen_fibrous_markdown_native"))()
return { attach = function(host, get_size, on_flush)
  return adapter.attach(host, get_size, on_flush, lib)
end }
